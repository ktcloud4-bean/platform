# 네트워크 정책 검증

`vlan-verify`는 네트워크를 변경하지 않고 route, DNS, TCP/UDP, SSH, TLS,
HTTP를 각각 판정한다. 주소는 이 문서가 소유하지 않는다. 실행할 때
[`docs/ip-plan.md`](../../docs/ip-plan.md)의 현재값을 명시적으로 입력한다.

```sh
infra/network/scripts/vlan-verify profiles
python3 -m unittest discover -s infra/network/tests -v
```

표준 Python 3 라이브러리와 읽기 전용 `ip -j route get`, socket 연결만
사용한다. 방화벽, interface, route, DNS 설정을 쓰는 기능은 없다. ICMP 실패는
차단 증거로 사용하지 않는다.

## profile 경계

| profile | 실행 범위 | 판정 경계 |
|---|---|---|
| `bootstrap` | `phase1-untagged-lan`, `observer`, 실제 `vlan` | 구축 중 DNS·NTP·인터넷·관리 접근과 입력한 기본 차단 probe |
| `hardened` | 실제 `vlan`만 | 입력한 명시적 허용과 기본 deny를 모두 포함한 probe plan |

`phase1-untagged-lan`이나 `observer`의 `PASS`는 선택한 현재망 회귀 항목만
뜻한다. VLAN 정책 전체를 통과했다는 뜻이 아니다. `hardened`는 `vlan_id`가
있는 출발지, 실제 source CIDR과 일치하는 route, ALLOW와 BLOCK probe 쌍이
없으면 성공할 수 없다. 아직 존재하지 않는 VLAN에서 실행하거나 Phase 1
scope를 주면 입력 오류(exit `2`)다.

profile은 포트나 service alias를 자동으로 만들지 않는다. NET-03/NET-04에서
실제로 배포하고 확정한 통신만 JSON plan에 추가한다. 따라서 미배포 서비스의
미확정 포트를 `hardened` 성공으로 대신할 수 없다.

## 현재 Phase 1 회귀

`phase1` 명령은 선택한 항목의 plan을 메모리에서 만들며 로컬 주소를 내장하지
않는다. 아래 자리표시자는 실행 직전 `docs/ip-plan.md`와 검증된 runbook 값으로
채운다.

```sh
infra/network/scripts/vlan-verify phase1 \
  --profile bootstrap \
  --scope phase1-untagged-lan \
  --source-name '<실제 Phase 1 출발 위치>' \
  --source-cidr '<현재 Phase 1 CIDR>' \
  --source-interface '<실제 interface>' \
  --checks gateway,dns,ntp,proxmox,external \
  --gateway '<gateway IP>' \
  --gateway-name '<gateway canonical name>' \
  --gateway-https-port '<검증된 HTTPS port>' \
  --gateway-tls-mode transport \
  --dns-server '<resolver IP>' \
  --dns-expect '<gateway canonical name>=<gateway IP>' \
  --dns-expect '<Proxmox canonical name>=<Proxmox IP>' \
  --ntp-hostname '<명시적 NTP target>' \
  --proxmox-host '<Proxmox IP>' \
  --proxmox-name '<Proxmox canonical name>' \
  --proxmox-ssh-port '<검증된 SSH port>' \
  --proxmox-https-port '<검증된 HTTPS port>' \
  --proxmox-tls-mode transport \
  --external-hostname '<명시적 외부 HTTPS target>' \
  --external-https-port '<검증할 HTTPS port>'
```

`transport`는 자체 서명 인증서를 쓰는 현재 관리면에서 TLS protocol 연결만
검증한다. 이 모드는 출력에 `certificate_validation=disabled`를 남긴다. CA를
검증할 수 있으면 mode 기본값 `verify`와 `--gateway-ca-file` 또는
`--proxmox-ca-file`을 사용한다. 외부 HTTPS는 항상 시스템 trust store로
인증서를 검증한다.

실행 호스트가 Phase 1 LAN에 직접 있지 않으면 `--scope observer`로 실제 출발
CIDR/interface를 적는다. observer 결과를 Phase 1 직접 출발 증거로 바꾸어
부르지 않는다. 원격 Linux 호스트에서 파일을 만들지 않고 실행해야 할 때는
스크립트를 표준입력으로 전달할 수 있다.

```sh
ssh <read-only-verified-host> 'python3 - phase1 <명시적 인자...>' \
  < infra/network/scripts/vlan-verify
```

`--checks`는 필요한 위치에서 `gateway`, `dns`, `ntp`, `proxmox`, `external`을
나눠 실행할 수 있다. 완료 증거에는 선택 항목과 실제 source/interface가 모두
남는다.

## VLAN plan 계약

`run`은 JSON plan을 받는다. 다음 예시는 문서 주소가 아닌 RFC 5737 TEST-NET
fixture다.

```json
{
  "schema_version": 1,
  "scope": "vlan",
  "source": {
    "name": "fixture-source",
    "cidr": "192.0.2.0/24",
    "interface": "eth0",
    "vlan_id": 20
  },
  "probes": [
    {
      "id": "fixture-route",
      "layer": "route",
      "destination_location": "fixture service",
      "destination": "198.51.100.10",
      "expected": "ALLOW",
      "reason": "상위 probe 전 route/source 전제를 확인한다."
    },
    {
      "id": "fixture-tcp",
      "layer": "tcp",
      "destination_location": "fixture service",
      "destination": "198.51.100.10",
      "port": 443,
      "expected": "ALLOW",
      "reason": "확정된 명시적 허용을 확인한다.",
      "dependencies": ["fixture-route"]
    }
  ]
}
```

```sh
infra/network/scripts/vlan-verify run \
  --profile bootstrap \
  --plan /path/to/plan.json
```

각 비-route probe는 앞선 route probe를 직접 dependency로 가져야 한다. DNS로
목적지를 얻을 때는 `destination_from`에 앞선 DNS probe ID를 쓰고 dependency에도
포함한다. TLS는 같은 대상의 TCP, HTTPS는 같은 대상의 TCP와 TLS를 선행시킨다.
이 계약 때문에 route, DNS, TCP, TLS, HTTP 중 어느 계층이 실패했는지 한 결과로
뭉개지지 않는다.

## 차단 판정과 대조 증거

BLOCK은 TCP 또는 응답을 검증할 수 있는 NTP/UDP에만 사용한다. 각 BLOCK probe는
다음을 모두 명시해야 한다.

- 다른 허용 출발지에서 같은 destination, port, protocol을 `ALLOW PASS`로 관측한
  `control_probe`
- 실제 통제 지점인 `enforcement_point`
- route/source가 PASS인 선행 probe

허용 출발지 결과를 JSON으로 보관하고 차단 출발지 실행에 넘긴다.

```sh
infra/network/scripts/vlan-verify run \
  --profile bootstrap \
  --plan /path/to/allow-plan.json \
  --format json > /tmp/vlan-verify-allow.json

infra/network/scripts/vlan-verify run \
  --profile bootstrap \
  --plan /path/to/block-plan.json \
  --evidence /tmp/vlan-verify-allow.json
```

대조 증거 기본 유효시간은 900초이며 `--control-max-age`로 더 짧게 만들 수 있다.
대상이 열려 있다는 대조 증거 없이 timeout 또는 connection refused만 관측하면
`INCONCLUSIVE`다. 대조 증거가 있을 때 timeout은 drop, connection refused는
reject로 구분해 PASS한다. 연결이 열리면 즉시 정책 위반 `FAIL`이다.

PostgreSQL과 MinIO처럼 source와 destination이 같은 VLAN/CIDR이면 OPNsense를
지나지 않을 수 있다. 이 흐름에 `enforcement_point: opnsense`를 쓰면 입력 오류로
거부한다. 향후 `host-or-proxmox` 통제와 그 위치의 독립 증거로 검증한다.

## 판정과 종료 코드

각 결과는 출발 위치, 실제 source/interface, 목적지, 계층/프로토콜, 기대값,
정책 근거, 관측값과 판정 근거를 출력한다.

| 종료 코드 | 전체 상태 | 의미 |
|---|---|---|
| `0` | `PASS` | 입력한 모든 probe가 기대와 일치 |
| `1` | `FAIL` | 하나 이상의 기대 ALLOW 실패 또는 기대 BLOCK 위반 |
| `2` | 입력 오류 | profile, scope, plan 또는 인자 계약 위반 |
| `3` | `INCONCLUSIVE` | source/route/DNS/대상 서비스/대조 증거 전제가 불충분 |

하나의 실행에 `FAIL`과 `INCONCLUSIVE`가 함께 있으면 확정된 위반을 우선해 exit
`1`이다. ALLOW TCP timeout은 `FAIL`, connection refused는 대상 서비스 부재가
가능하므로 `INCONCLUSIVE`다. 선행 계층이 PASS가 아니면 뒤 계층도 PASS로
승격하지 않는다.

## 중단과 복구

도구는 설정을 쓰지 않으므로 네트워크 rollback이 없다. 잘못된 destination이나
예상하지 않은 부하가 보이면 프로세스를 중단하면 된다. JSON 결과처럼 사용자가
명시적으로 redirect한 로컬 파일만 필요에 따라 삭제한다. OPNsense API/UI,
`config.xml`, Proxmox network, VLAN, firewall, DHCP와 DNS 설정은 이 도구의 소유
범위가 아니다.
