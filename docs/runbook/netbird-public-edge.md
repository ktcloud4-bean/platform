# NetBird 단독 공개 진입 경계

- 작업: `EDGE-01`
- 공개 hostname: `netbird.imcherry5778.xyz` 하나
- 후속: `EDGE-02 READY` (`sso` Keycloak 사용자 프런트엔드만 Cloudflare proxy로 공개)

## 목적과 경계

외부 사용자는 NetBird control·relay에만 직접 도달한다. Pomerium Portal과 Keycloak issuer를
포함한 웹 서비스는 NetBird 연결 뒤 내부 DNS로 사용한다. 이는 `EDGE-01`의 검증된 현재 경계다.
2026-08-04 외부 신규 장치가 기존 팀 ID로 NetBird OIDC 로그인을 시작해야 한다는 요구가 생겨
[ADR-0018](../adr/0018-public-keycloak-frontchannel.md)에서 `sso` 사용자 프런트엔드만 공개하기로
결정했다. `EDGE-02 DONE` 전까지 공개 상태는 바뀌지 않으며 `access` Portal과 애플리케이션은
후속 적용 뒤에도 NetBird 내부에 남는다.

```text
외부 peer → public DNS-only netbird A → OPNsense WAN
          ├─ TCP 80  → netbird-01:80
          ├─ TCP 443 → netbird-01:443
          └─ UDP 3478 → netbird-01:3478
                          └─ DMZ(vlan04) Suricata alert-only 관찰

NetBird 연결 뒤 → 내부 DNS → access/sso/Warpgate 및 허용된 내부 서비스

등록된 recovery client → NetBird direct peer → warpgate-01:8888
```

`EDGE-02` target은 Cloudflare proxied `sso`가 NetBird WAN TCP 443과 분리된 origin port로
k3s Keycloak에 도달하는 경로다. exact target과 rollback은
[Keycloak 공개 사용자 프런트엔드 런북](keycloak-public-frontchannel.md)이 소유한다. 이 경로는
외부 OIDC bootstrap만 해결하며 일반 사용자 route·split DNS는 `NB-ENROLL-01`이 소유한다.

다음은 `EDGE-01`에서 하지 않는다.

- Cloudflare proxy·WAF·rate limit·Authenticated Origin Pull
- `access`·`sso`·`k3s-01` 또는 애플리케이션 alias의 공개 A/AAAA
- Traefik 대상 WAN NAT, 정적 entrypoint·plugin·Pod 재기동
- NetBird 기존 NAT·서비스·인증서 변경과 IPv6 공개
- NetBird subnet route·exit node·NetBird SSH 활성화
- Suricata IPS 승격이나 CrowdSec Cloudflare bouncer 활성화

## 승인된 공개 객체

| 계층 | 객체 | 최종 상태 |
|---|---|---|
| Cloudflare DNS | `netbird.imcherry5778.xyz` A | DNS-only, 기존 WAN IPv4, TTL 120초 |
| Cloudflare DNS | 그 밖의 A·AAAA·CNAME | 0건 |
| OPNsense NAT | WAN TCP 80 → `netbird-01` TCP 80 | 기존 `NB-01` 객체 유지 |
| OPNsense NAT | WAN TCP 443 → `netbird-01` TCP 443 | 기존 `NB-01` 객체 유지 |
| OPNsense NAT | WAN UDP 3478 → `netbird-01` UDP 3478 | 기존 `NB-01` 객체 유지 |
| Cloudflare proxy/origin | 없음 | 현재 `EDGE-01` 완료 상태; `EDGE-02 READY` target은 별도 런북이 소유 |
| OPNsense filter | `warpgate-01/32` → `netbird-01/32` TCP 443 | EDGE-01 direct peer control 연결만 허용 |

OPNsense NAT UUID와 내부 주소는 마스킹 스냅샷 `infra/opnsense/config.xml`과
`docs/ip-plan.md`가 소유하므로 이 문서에 복제하지 않는다. `EDGE-01`은 OPNsense live 객체를
위 filter rule 하나 외에는 바꾸지 않으며 작업 시작 일반 drift 검사가 성공한 상태를 기준으로
한다. 신규 NAT·alias·공개 IPv6 rule은 만들지 않는다.

## Warpgate 복구 overlay 선언

Warpgate에 NetBird agent를 직접 설치해 overlay 종단으로 삼는다. Warpgate가 다른 VLAN의
subnet router가 되지 않으므로 기존 Warpgate egress 경계와 OPNsense의 VLAN 정책을 우회하지
않는다.

### OPNsense control rule

NET-04의 ACCESS 규칙에서 OIDC 허용 뒤, 비공개 목적지 차단 앞에 아래 rule 하나를 넣는다.
처음에는 disabled로 stage하고 API readback에서 모든 의미값을 대조한 뒤에만 활성화한다.

| 필드 | 선언값 |
|---|---|
| interface·direction | `opt3`(ACCESS) inbound quick |
| family·protocol | IPv4 TCP |
| source | `warpgate-01/32` |
| destination·port | `netbird-01/32` TCP 443 |
| action·state·log | pass, keep state, log |
| sequence·description | `1119`, `EDGE-01 Warpgate to NetBird control` |

### NetBird group·policy

| 객체 | 선언값 |
|---|---|
| group `edge-recovery-clients` | 승인된 복구 client peer만 포함 |
| group `edge-recovery-warpgate` | persistent `warpgate-edge` peer 하나만 포함 |
| policy `EDGE-01 Warpgate recovery` | source clients → destination Warpgate, TCP 8888, accept, enabled, 단방향 |
| policy `Default` | 의미값은 보존하고 enabled만 `false` |

`Default` All↔All을 그대로 두면 위 최소 정책과 무관하게 모든 peer가 서로 통신할 수 있으므로
반드시 비활성화한다. EDGE policy는 Warpgate의 HTTP listener만 허용하며 SSH 2222, 다른 peer,
LAN subnet과 route resource를 허용하지 않는다.

### peer와 setup key 수명

Warpgate agent는 NetBird server와 같은 `v0.73.0` RPM을 GitHub Release SHA-256으로 고정한다.
선언은 [`warpgate_netbird_peer`](../../infra/ansible/roles/warpgate_netbird_peer) role과
[`warpgate-netbird-peer.yml`](../../infra/ansible/playbooks/warpgate-netbird-peer.yml)이 소유한다.
agent의 DNS·client route·server route·overlay IPv6를 끄고 interface는 `wt0` 하나만 쓴다.

등록용 key는 `one-off`, usage limit 1, 만료 24시간으로 만든다. Warpgate key는 persistent
peer를 `edge-recovery-warpgate`에 자동 배정하고, 검증 client key는 ephemeral peer를
`edge-recovery-clients`에 자동 배정한다. 원문은 저장소 밖 owner-only 디렉터리의 mode
`0600` 파일로만 전달하며 등록 직후 API key와 로컬·원격 원문을 제거한다. 전용 도구는
[`netbird-recovery-policy.py`](../../infra/ansible/tools/edge-01/netbird-recovery-policy.py)와
[`netbird-recovery-assets.py`](../../infra/ansible/tools/edge-01/netbird-recovery-assets.py)다.

## 이전 프로젝트 DNS 잔여 정리

Cloudflare zone의 작업 전 전체 32개 레코드는 저장소 밖 mode `0600` JSON으로 보관한다.
스냅샷은 `${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/edge-01/` 아래에 두며 API token이나
Secret은 포함하지 않는다. 승인된 삭제 선택자는 다음 두 그룹과 작업 전 snapshot의 exact
record ID가 모두 일치하는 31개뿐이다.

1. type `A`, content가 이전 `acer-mgmt`의 Tailscale CGNAT 주소와 exact 일치하는 26개
2. `ggg`·`khb`·`ljw`·`nmg`·`oje` type `CNAME`, content가 snapshot의 각
   `*.cfargotunnel.com`과 exact 일치하고 proxied인 5개

이 레코드들은 2026-07-03~12에 이전 프로젝트 자동화가 만들었고 사용자가 더 이상 사용하지
않는다고 확인했다. CNAME 5개는 작업 전 HTTPS에서 모두 Cloudflare `530`이어서 tunnel origin도
동작하지 않았다. exact record ID로 31개를 삭제하고 `netbird` A만 보존했다. 보존한 A의 시작
값이 현재 OPNsense WAN IPv4와 달라 외부 HTTPS가 timeout 난 원인을 특정한 뒤 현재 WAN 값으로
교정했다. snapshot 밖의 새 record는 선택하지 않는다. 삭제·교정 전후
API 응답에는 record 값과 metadata만 사용하고 token을 출력하지 않는다.

## 완료 증거 세 항목

완료 판정은 아래 세 항목만 각각 한 번 실행한다. VLAN 경계, Pomerium policy, CrowdSec
판정과 재부팅은 다시 검증하지 않는다.

| 증거 | 단일 검증 방법 |
|---|---|
| 공개 권위 DNS allowlist | Cloudflare 두 authoritative NS를 한 실행에서 직접 질의해 DNS-only `netbird` A 1건, 그 밖의 A·AAAA·CNAME 0건을 판정하고 랩 밖 HTTPS 요청의 정상 응답을 함께 확인 |
| WAN NAT allowlist | OPNsense 저장 설정과 PF runtime을 한 번 대조해 inbound NAT가 NetBird TCP 80/443·UDP 3478 세 개뿐이고 다른 공개 origin/NAT가 없음을 판정 |
| IDS 관측·복구 독립 | 랩 밖 NetBird control 트래픽의 같은 시각을 Suricata `eve.json`에서 확인하고, 연결된 peer가 Cloudflare proxy 없이 내부 Warpgate 복구 경로에 도달함을 한 실행에서 판정 |

Cloudflare 권위 NS 직접 질의는 recursive cache를 쓰지 않으므로 삭제된 TTL 60초를 기다리지
않는다. 외부 recursive resolver를 대조해야 할 때만 기존 TTL 60초와 SOA negative TTL
1800초 중 해당 질의에 적용되는 값을 먼저 계산하며 반복 조회로 cache를 우회하지 않는다.

### 2026-08-03 적용 결과

| 증거 | 결과 |
|---|---|
| 공개 권위 DNS allowlist | 두 authoritative NS 모두 DNS-only `netbird` A 한 건만 응답하고 그 밖의 A·AAAA·CNAME은 0건이었다. 일본 외부 probe의 `netbird` HTTPS는 같은 WAN IPv4로 HTTP 200을 반환했다. |
| WAN NAT allowlist | OPNsense 저장 설정과 PF runtime의 inbound NAT는 NetBird TCP 80·443, UDP 3478 세 건으로 일치했고 그 밖의 공개 origin/NAT는 없었다. |
| IDS 관측·복구 독립 | 일본 외부 probe가 만든 NetBird TCP 443 흐름을 Suricata `eve.json`에서 `2026-08-03T05:55:55.172125+0900`에 관측했다. 별도 network namespace의 ephemeral peer는 `wt-edge01` direct-peer route로 내부 DNS의 Warpgate HTTPS 8888을 한 번에 통과했다. Warpgate에는 public DNS·NAT가 없고 Cloudflare proxy도 사용하지 않았다. |

Warpgate의 persistent `warpgate-edge` peer는 `v0.73.0`, connected, non-ephemeral이며
`edge-recovery-warpgate` group 하나에만 명시적으로 배정됐다. role 2차 적용은
`changed=0`이었다. 검증용 one-off key·ephemeral peer·container·state와 고정 검증 image는
판정 직후 제거했다. 최초 검증기 연결 실패는 management·relay 연결 이후 raw socket 생성이
`operation not permitted`로 끝난 것이 원인이었고, 격리 container에 누락된 `CAP_NET_RAW`만
보정한 뒤 위 단일 완료 판정을 실행했다.

### Rollback 기준점

저장소 밖 `${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/edge-01/`의 다음 mode `0600`
파일을 작업 시작 상태의 단일 rollback 입력으로 보존한다.

| 계층 | 파일·기준 |
|---|---|
| Cloudflare | `cloudflare-dns-pre-edge-01-20260802T202556Z.json`, SHA-256 `39b7837a8e99291f9c4dd8f47dfc4a8c0ad9978443107c6051d12dec462f5e6c` |
| OPNsense | `opnsense-config-pre-edge-01.raw.xml`, revision `1785684950.31`, SHA-256 `e2e385342f80a24dfc9de68d40b8e811cf9f13ef43cbbe398bee9db122de326e` |
| NetBird | `netbird-policy-pre-edge-01.json`, SHA-256 `e6a45d401323fff11f19856669de1917aece5f466ff7c43c8e2552a3275dd5a1` |

## Rollback

Cloudflare 삭제 도중 일부만 실패하면 추가 변경 전에 batch 응답에서 실패한 record ID를
특정한다. 삭제 전 전체 JSON의 31개 원본 `name`·`type`·`content`·`ttl`·`proxied`·`comment`를
그대로 다시 생성하고 두 authoritative NS에서 복구를 확인한다. 새 record ID가 생기는 것은
Cloudflare API 특성이며 의미값은 원본과 같아야 한다.

Warpgate 복구 overlay 적용이 실패하면 검증 peer와 key를 먼저 제거하고, Management API에서
exact `warpgate-edge` peer를 삭제한다. Warpgate에서 `netbird down` 후 서비스를 disable·stop하고
고정 RPM과 `/var/lib/netbird`의 EDGE-01 client 상태만 제거한다. 이어 `Default`를 다시 활성화하고
exact EDGE policy와 비어 있는 두 group을 삭제한다. 이름만 같은 객체의 의미값이나 group
membership이 달라졌으면 자동 삭제하지 않는다.

OPNsense는 EDGE-01 rule UUID만 disable하고 filter를 적용한 뒤 저장 의미값과 PF runtime에서
사라진 것을 확인해 삭제한다. 관리 경로가 끊기면 PiKVM OOB 콘솔에서 작업 시작 raw config
revision으로 복구한다. 기존 NetBird NAT 세 개, LAN/HOME, interface·gateway, Suricata와 다른
NET-04 rule은 건드리지 않는다. `config.xml`은 apply 입력이 아니며 라이브 복구는 지원되는
UI/API·설정 라이브러리만 사용한다.

`EDGE-02`를 적용했다가 실패하면 NetBird DNS-only A와 세 NAT는 rollback 대상이 아니다.
[후속 런북](keycloak-public-frontchannel.md)의 `sso` Cloudflare·OPNsense 객체만 제거해 이
runbook의 NetBird 단독 경계로 돌아온다.
