# AWS 사설 착지점 · OpenTofu

`AWS-NET-01`이 소유한다. 토폴로지와 경계 결정은
[ADR-0011](../../../docs/adr/0011-aws-site-to-site-vpn-boundary.md), state 경계 원칙은
[ADR-0008](../../../docs/adr/0008-opentofu-provider-and-state-boundary.md)가 소유한다.
적용·검증·중단·rollback 절차는
[docs/runbook/aws-site-to-site-vpn.md](../../../docs/runbook/aws-site-to-site-vpn.md)가
소유한다.

## 이 root가 소유하는 것

온프레미스와 AWS를 잇는 사설 경로만 소유한다. VPC, 사설 서브넷, route table, VGW,
Customer Gateway, Site-to-Site VPN과 검증 전용 자원이 전부다.

**오프사이트 백업 root(`infra/aws/tofu`)와 state를 공유하지 않는다.** 백업 bucket은
지워지면 안 되는 자산이라 `prevent_destroy`가 걸려 있고, 이 root의 VPN은 비용 때문에
언제든 내릴 수 있어야 한다. 한 state에 두면 그 두 요구가 서로를 막는다. 계정 안의 다른
자원(default VPC, CloudTrail bucket 등)은 `resource`로 선언하지도 `import`하지도 않는다.

오프사이트 백업 전송은 계속 공인 AWS API endpoint로 나간다. 이 VPN으로 옮기지 않는다.
백업 경로가 터널에 의존하면 터널 장애가 곧 백업 중단이 된다.

## 구조

```text
OPNsense WAN ──── IPsec (IKEv2, policy-based, static) ──── VGW
   │                                                        │
 DATA VLAN                                              사설 서브넷
                                                        (IGW 없음)
```

- **VGW + static routing.** BGP를 쓰지 않으므로 터널이 기본 경로를 바꿀 수 없다.
- **policy-based.** traffic selector를 양쪽 대역으로 좁혀 그 밖의 트래픽은 SA에
  실리지 않는다. 대역 제한이 방화벽 규칙 하나에만 걸려 있지 않다.
- **인터넷 gateway 없음.** 이 VPC의 유일한 외부 경로가 VPN이다.
- **터널 1개만 온프레미스에 구성.** AWS는 항상 터널 2개를 만들고 추가 요금은 없지만,
  policy-based에서 같은 selector로 두 SA를 유지하면 활성 경로가 불명확해진다.
  AWS 터널 유지보수 중 단절될 수 있다는 한계는 ADR-0011이 기록한다.

## 실행

실제 변수값은 저장소 밖 파일에 둔다. 계정 ID와 WAN 공인 IP를 커밋하지 않는다.

```bash
cd infra/aws/tofu-network
tofu init
tofu plan  -var-file=<저장소 밖 tfvars>
# 명시적 승인 뒤에만 실제 적용
tofu apply -var-file=<저장소 밖 tfvars>
```

관리자 자격증명은 AWS CLI profile 또는 표준 환경변수로만 주입한다.
`allowed_account_ids`가 provider 단계에서 계정을 강제하므로 다른 계정 자격증명으로
실행하면 plan이 실패한다.

## 고정 값

| 항목 | 값 | 근거 |
|---|---|---|
| OpenTofu | `~> 1.12` (1.12.5로 검증) | `versions.tf` |
| AWS provider | `hashicorp/aws` 6.56.0 | 정확히 고정. 루트 `.gitignore`가 lock 파일을 제외하므로 재현성의 근거가 이 줄뿐이다. 오프사이트 root와 같은 버전을 쓴다 |
| region | `ap-northeast-2` | 오프사이트 bucket과 같은 region |
| IKE | IKEv2, AES256 / SHA2-256 / DH group 14 | 양쪽에 같은 값을 명시해 협상 결과가 사후 확인 대상이 되지 않게 한다 |

주소는 이 문서가 소유하지 않는다. 대역과 그 선택 이유는
[`docs/ip-plan.md`](../../../docs/ip-plan.md)를 따른다.

## gate

| 변수 | 기본값 | 언제 여는가 |
|---|---|---|
| `create_vpn_connection` | `true` | **이 root의 상시 비용은 사실상 전부 이 자원 하나에서 나온다.** 닫으면 과금 자원이 0이 되고 VPC·서브넷·VGW만 남는다 |
| `create_verify_instance` | `false` | 양방향 통신 증거를 만들 때만 연다. 증거를 확보하면 닫아서 제거한다 |
| `verify_onprem_probe_target` | `""` | AWS→온프레미스 방향을 증명할 때 `IP:PORT`로 지정한다 |

`onprem_cidr`를 넓히는 것은 단순한 값 변경이 아니다. IPsec traffic selector, AWS static
route, security group이 모두 이 값을 쓰므로 통신 가능 범위 자체가 넓어진다. 랩 전체로
열지 않는다.

## state와 자격증명

state backend는 local이다. **이 state에는 tunnel pre-shared key가 평문으로 들어간다.**
AWS가 생성한 PSK는 state와 API 응답에만 존재하므로 선언형으로 다루려면 state에 남는 것을
받아들여야 한다. 그래서 이 디렉터리의 `.gitignore`는 `*.tfstate`, `*.tfvars`, `*.tfplan`과
자격증명이 떨어질 수 있는 이름을 함께 막는다.

state 사본과 회수한 PSK는 저장소 밖 mode `0600` 파일에만 둔다.

```bash
# 터널 PSK 회수 (값을 화면에 남기지 않는다)
umask 077
tofu output -raw tunnel1_preshared_key > <저장소 밖 경로>/aws-tunnel1.psk
```

이 값은 OPNsense의 Pre-Shared Keys에 사람이 직접 입력한다. OPNsense 설정 스냅샷에는
`normalize.py`가 PSK를 제거한 뒤에만 커밋한다. 그 동작은
`infra/opnsense/tests/test_normalize.py`가 회귀로 고정한다.

## 폐기

VPN Connection에는 `prevent_destroy`를 걸지 않는다. 비용 때문에 내릴 수 있어야 하는
설비이기 때문이다. 연결만 내리려면 `create_vpn_connection`을 닫는다.

```bash
tofu apply -var-file=<저장소 밖 tfvars> -var 'create_vpn_connection=false'
```

**AWS 쪽 연결을 내려도 OPNsense 쪽 설정은 남는다.** 두 쪽을 함께 되돌리는 것은 사람의
절차이며 runbook이 소유한다. OPNsense 설정을 남긴 채 AWS만 지우면 터널이 영원히
재연결을 시도한다.

VPC·서브넷·VGW는 과금되지 않으므로 남겨 두어도 비용이 늘지 않는다. 전체를 지우려면
`tofu destroy`를 쓰되, 이 root가 오프사이트 백업 자원을 사정권에 두지 않는다는 점을
plan으로 먼저 확인한다.
