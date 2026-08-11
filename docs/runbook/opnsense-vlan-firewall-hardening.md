# OPNsense VLAN 방화벽 최소화

- 작업: `NET-04`
- 적용·검증일: 2026-08-03
- 상태: 실제 배포 서비스 통신표 적용, `vlan-verify hardened`, drift 없음

## 목적과 경계

`NET-03`의 VLAN 단위 bootstrap 규칙을 현재 배포된 다섯 VM의 host 단위 규칙으로
교체하고, 실제 서비스가 요구하는 cross-VLAN 경로만 허용한다. 정확한 주소와 VLAN 대역의
단일 원본은 [`docs/ip-plan.md`](../ip-plan.md)다. 아래 `/32`는 그 문서에 `LIVE`로 적힌
호스트 주소 한 개를 뜻하며 주소를 이 문서에 복제하지 않는다.

다음은 바꾸지 않았다.

- 기존 LAN/HOME 규칙, interface·gateway, automatic outbound NAT, DHCP
- Suricata, Proxmox 영속 network, IPsec connection과 traffic selector
- 공개 DNS/NAT/Cloudflare/origin, IPv6 정책
- 같은 DATA VLAN 안에서 OPNsense를 지나지 않는 `postgres-01`↔`object-01` 통신

## 최종 통신표

모든 규칙은 ingress interface의 IPv4 quick rule이다. PASS는 state를 유지하며
cross-VLAN PASS와 비공개 목적지 BLOCK은 기록한다. 표에 없는 신규 연결은 PF implicit
deny가 처리한다.

| 출발 source host/CIDR | 도착 host | 프로토콜·포트 | 방향 | 판정 | 소유 작업·근거 |
|---|---|---|---|---|---|
| `k3s-01/32` | PLATFORM gateway | TCP·UDP 53 | `opt2` inbound | ALLOW | `NET-04`; 노드·Pod 이름 해석 |
| `k3s-01/32` | PLATFORM gateway | UDP 123 | `opt2` inbound | ALLOW | `NET-04`; 노드 시간 동기화 |
| `k3s-01/32` | `postgres-01/32` | TCP 5432 | `opt2` inbound | ALLOW | `NET-03A`, `VAULT-02`; TLS PostgreSQL |
| `k3s-01/32` | `object-01/32` | TCP 8333 | `opt2` inbound | ALLOW | `S3-01`, `BKP-01`~`BKP-05`; TLS S3 |
| `warpgate-01/32` | ACCESS gateway | TCP·UDP 53 | `opt3` inbound | ALLOW | `NET-04`; Warpgate 이름 해석 |
| `warpgate-01/32` | ACCESS gateway | UDP 123 | `opt3` inbound | ALLOW | `NET-04`; Warpgate 시간 동기화 |
| `warpgate-01/32` | `k3s-01/32` | TCP 443 | `opt3` inbound | ALLOW | `WG-02`; Keycloak OIDC backend |
| `warpgate-01/32` | `NET04_WARPGATE_SSH_TARGETS` | TCP 22 | `opt3` inbound | ALLOW | `WG-01`, `WG-02`; 현재 관리 대상 SSH 중계 |
| `warpgate-01/32` | `postgres-01/32` | TCP 5432 | `opt3` inbound | ALLOW | `WG-04`; native PostgreSQL TLS relay |
| `netbird-01/32` | DMZ gateway | TCP·UDP 53 | `opt4` inbound | ALLOW | `NET-04`; NetBird 이름 해석 |
| `netbird-01/32` | DMZ gateway | UDP 123 | `opt4` inbound | ALLOW | `NET-04`; NetBird 시간 동기화 |
| `netbird-01/32` | `k3s-01/32` | TCP 443 | `opt4` inbound | ALLOW | `NB-02`; Keycloak OIDC·Admin/control API |
| `NET04_DATA_HOSTS` | DATA gateway | TCP·UDP 53 | `opt5` inbound | ALLOW | `NET-04`; PostgreSQL·S3 이름 해석 |
| `NET04_DATA_HOSTS` | DATA gateway | UDP 123 | `opt5` inbound | ALLOW | `NET-04`; PostgreSQL·S3 시간 동기화 |
| 다섯 배포 VM의 각 `/32` | public IPv4 | TCP 80·443 | 해당 VLAN inbound | ALLOW | OS·이미지·API 갱신; DATA 443은 공인 AWS S3/SNS/CloudWatch 포함 |
| 다섯 배포 VM의 각 `/32` | `NET04_NONPUBLIC_V4` | IPv4 전체 | 해당 VLAN inbound | BLOCK·기록 | 내부·특수용 목적지 기본 차단; 위의 exact 예외가 먼저 평가됨 |

`NET04_DATA_HOSTS`는 `postgres-01`과 `object-01`,
`NET04_WARPGATE_SSH_TARGETS`는 현재 배포된 OPNsense·Proxmox·k3s·NetBird·PostgreSQL·
object host만 포함한다. `NET04_NONPUBLIC_V4`는 RFC1918뿐 아니라 비공개·loopback·
link-local·CGN·문서·benchmark·multicast·reserved IPv4를 포함하므로 뒤의 public Web
허용이 내부 관리면을 우회하지 못한다.

AWS VPC 전체 프로토콜 허용은 실제 서비스 소비자가 없어 제거했다. IPsec 선언과
DATA↔VPC selector는 유지하지만 DATA에서 VPC로 시작하는 통신은 기본 차단이다. 오프사이트
백업은 기존처럼 public AWS API의 TCP 443을 쓴다. 외부에서 내부로 시작하는 공개 경로는
`EDGE-01` 범위라 이 표에 추가하지 않았다.

## 최종 저장 객체

| interface | sequence와 UUID | 의미 |
|---|---|---|
| `opt2` | `1002` `b5756159-a650-4b13-b474-ff61efa2a3f3`; `1012` `25d7180e-7ef7-47a3-bdd6-b11e3014070f`; `1018` `c10373d1-3158-45ff-83f0-199385d46671`; `1022` `72723db0-524d-4098-8e84-a54f8548610c`; `1032` `23d19d9b-dd08-4920-8082-19cc0bbcf890` | k3s DNS, NTP, PostgreSQL, non-public BLOCK, public Web |
| `opt3` | `1102` `fc3cea96-d45e-4694-bf5e-ba0fa7113dcb`; `1112` `ca0af6b5-5356-4572-8646-e03e2b88d665`; `1117` `7e9fcac3-e5da-43e1-96a3-dee968e28a9b`; `1118` `21422214-412c-4596-84e5-062bba81b2da`; `1120` `cdb5d60d-91be-4144-b4eb-e74dcd652dfb`; `1122` `f1ec0a02-e42e-455b-b09c-98ba69a54f1d`; `1132` `f4d8cbe0-4ba0-48b3-8a1f-6981339324e2` | Warpgate DNS, NTP, OIDC, SSH, PostgreSQL TLS relay, non-public BLOCK, public Web |
| `opt4` | `1202` `590dc3ac-13b4-4855-8bcf-806c2bd58a87`; `1212` `da27944c-dc48-40ce-bcbf-056686579ac9`; `1218` `b0ba06fb-54b9-4cbd-9830-106d2ca71f22`; `1222` `be877eb8-4ccf-4f72-839f-a5074efa83ec`; `1232` `3f6fa0bd-614d-4cb4-8612-69148cf30b2b` | NetBird DNS, NTP, Keycloak/control, non-public BLOCK, public Web |
| `opt5` | `1302` `2ee3f199-b683-4671-ba61-d000667ed165`; `1312` `6326c0ae-ba05-4933-a8ad-405d5fb00480`; `1322` `4afe287d-be72-4330-a9f8-35ea64b1a38f`; `1332` `6f28ee7a-87e4-4a97-8b15-6267c28ca483` | 두 DATA host DNS, NTP, non-public BLOCK, public Web |

`S3-01`의 기존 exact rule `58525b66-bc90-484e-893a-a51bfd5aa346`은 의미값과
sequence `1015`를 바꾸지 않고 보존했다. 최종 alias UUID는 다음과 같다.

| alias | UUID | 의미 |
|---|---|---|
| `NET04_NONPUBLIC_V4` | `9ea71b22-bb17-4a31-a69d-6931265db745` | public Web보다 먼저 차단할 비공개·특수용 IPv4 |
| `NET04_WEB_PORTS` | `07c69ab9-7c98-48b0-ab7c-420037e0bdba` | TCP 80·443 |
| `NET04_DATA_HOSTS` | `5bec8a78-4178-4122-992b-922f5940be05` | 현재 DATA VM 두 대 |
| `NET04_WARPGATE_SSH_TARGETS` | `32ab113e-45c1-4181-bb69-8a8a9f1f1155` | 현재 Warpgate SSH 관리 대상 여섯 대 |

## 임시 객체 처분과 적용

작업 전 revision은 `1785670201.97`이며 원본 config는 저장소 밖 mode `0700`
디렉터리에 mode `0600`으로 보관했다. 원본 SHA-256은
`4473996de469a884e45eba5461ea3144b84a96b17c3aacdde38852b06dda61f1`이다. 자격증명,
원본 config, WAN 값은 Git과 출력에 넣지 않았다.

신규 alias 4개와 rule 20개를 만들되 rule은 모두 disabled로 stage했다. API readback의
interface·direction·family·protocol·source·destination·port·action·state·logging·sequence·
description이 계획과 같은지 대조한 뒤 신규 rule을 enable하고 filter를 한 번 적용했다.
신규 PF runtime 20개와 기존 경계 20개가 함께 로드된 상태를 먼저 확인한 다음 아래 만료
대상을 제거하고 filter를 한 번 적용했다. 참조가 사라진 기존 alias는 마지막에 제거했다.

- `NET-03` interface 규칙 16개: VLAN별 DNS·NTP·RFC1918 BLOCK·broad Web
- `NET-03A` PostgreSQL 임시 rule `c23d9b13-b3a0-4205-852f-89e11d5cfe97`
- `WG-02` OIDC 임시 rule `9c303af2-c202-4e54-ad42-91d4ab1e1fdf`
- `NB-02` OIDC/control 임시 rule `6bcca3bc-b23f-4713-987f-dd4c34790f8a`
- `AWS-NET-01` DATA→VPC 전체 프로토콜 임시 rule `74df2205-ed1a-4d7c-80a2-52ee1fb67328`
- 임시 alias `NET03_PRIVATE_V4`, `NET03_BOOTSTRAP_WEB_PORTS`, `AWSNET01_VPC_V4`

최종 저장 의미값은 신규 rule `20/20`, 기존 만료 rule `0/20`, 신규 alias `4/4`, 기존
만료 alias `0/3`, 기존 S3 rule 보존으로 일치했다. PF syntax는 정상이고 runtime도 신규
`20/20`, 기존 `0/20`이었다. OPNsense 재부팅은 수행하지 않았다.

## hardened 검증

실제 source의 plan은 각각 한 번만 실행했다. 각 hardened plan은 명시적 ALLOW와 기본
BLOCK을 함께 포함했고, BLOCK은 같은 orchestration에서 먼저 성공한 MGMT ALLOW control의
동일 destination·protocol·port를 900초 TTL 안에 재사용했다.

| source plan | 결과 | BLOCK control |
|---|---|---|
| `k3s-01` | `13/13 PASS` (`ALLOW 12`, `BLOCK 1`) | MGMT→OPNsense TCP 443 ALLOW |
| `warpgate-01` | `21/21 PASS` (`ALLOW 20`, `BLOCK 1`) | MGMT→k3s TCP 6443 ALLOW |
| `netbird-01` | `10/10 PASS` (`ALLOW 9`, `BLOCK 1`) | MGMT→k3s TCP 6443 ALLOW |
| `postgres-01` | `9/9 PASS` (`ALLOW 8`, `BLOCK 1`) | MGMT→k3s TCP 443 ALLOW |
| `object-01` | `9/9 PASS` (`ALLOW 8`, `BLOCK 1`) | MGMT→k3s TCP 443 ALLOW |

MGMT control plan도 `5/5 PASS`였고, 검증 뒤 여섯 host에서 임시 verifier·plan이 모두
제거됐음을 확인했다. 같은 통신을 curl이나 packet capture로 다시 판정하지 않았고 verifier
코드는 바뀌지 않아 unit test를 실행하지 않았다.

의도한 rule·alias diff만 `check-drift.sh --update`로 승인한 직후 일반
`check-drift.sh`를 한 번 실행해 `드리프트 없음`을 확인했다.

## 실패 시 원상복구

반복 적용 전에 저장 rule, PF runtime, route, DNS, target listener, verifier evidence 중
어느 단계가 실패했는지 먼저 특정한다.

1. 전환 중 신규 경계가 실패하면 위에 기록한 NET-04 rule UUID만 disable하고 filter를
   적용한다. 기존 규칙이 함께 살아 있는 stage 구간에서는 신규 UUID를 삭제한 뒤 alias
   참조가 0인지 확인하고 신규 alias UUID만 삭제한다.
2. 기존 임시 경계를 제거한 뒤라면 OOB 콘솔에서 작업 전 revision `1785670201.97`을
   복원하고 filter·alias를 reconfigure한다. 저장 의미값과 PF runtime이 작업 전 UUID와
   순서로 돌아왔는지 확인한다.
3. strict 관리 경로가 끊기면 PiKVM OOB 콘솔을 사용한다. LAN/HOME, interface·gateway,
   NAT, IPsec, Suricata를 임의 변경하거나 broad allow를 만들지 않는다.
4. 복구 뒤 일반 drift가 작업 전 저장소 상태와 일치하는지 한 번 확인한다. 원본 config
   사본은 복구 근거이며 저장소 스냅샷을 OPNsense apply 입력으로 쓰지 않는다.
