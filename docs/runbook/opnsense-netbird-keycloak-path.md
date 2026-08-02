# OPNsense NetBird → Keycloak OIDC 최소 경로

- 작업: `NB-02`
- 적용일: 2026-08-01
- 선례: `NET-03A`의 출발지 한 대·목적지 한 대·포트 한 개 원칙

> 현재 상태(2026-08-03): 아래 임시 rule UUID는 `NET-04`에서 제거하고 동일한 exact
> host·TCP 443 의미의 최종 rule로 교체했다. 현재 UUID와 rollback은
> [`opnsense-vlan-firewall-hardening.md`](opnsense-vlan-firewall-hardening.md)가 소유한다.

## 판정

`netbird-01`은 Keycloak issuer discovery, JWKS, userinfo와 Keycloak Admin API를
backend에서 호출한다. DMZ VLAN 40의 RFC1918 BLOCK 때문에
`10.10.40.10 → 10.10.20.10:443` TLS 연결은 전환 전 실패했고, 해당 BLOCK PF
counter가 증가했다. 공개 resolver에는 `sso` A/AAAA가 없고 NAT도 없으므로 public
경로로 대체하지 않는다.

## 허용 정책

| 항목 | 값 |
|---|---|
| interface / direction | `opt4` (DMZ VLAN 40) / inbound |
| family / protocol | IPv4 / TCP |
| source | `10.10.40.10` (`netbird-01` 한 대) |
| destination | `10.10.20.10:443` (Keycloak ingress 한 대) |
| action / state / log | PASS / keep / enabled logging |
| sequence | `1216` — RFC1918 BLOCK `1220` 앞 |
| 최종 UUID | `6bcca3bc-b23f-4713-987f-dd4c34790f8a` |
| description | `NB-02: netbird-01에서 Keycloak OIDC TLS TCP 443만 허용; NET-04에서 실제 통신표로 재검토` |

VLAN 전체, 다른 source·destination·port, NAT, public DNS, Cloudflare, IPv6는 바꾸지
않는다. `NET-04`가 실제 통신표를 확정할 때 이 임시 최소 경로를 재검토한다.

## 적용·rollback

OPNsense 원본 config는 API backup endpoint에서 저장소 밖 mode 0700 evidence directory에
mode 0600으로 보관한다. `config.xml`은 drift snapshot이며 apply 입력이 아니다.

1. rule을 disabled로 만들고 API 저장값과 sequence를 대조한다.
2. 일치할 때만 enable → apply한다.
3. PF runtime에 UUID label, TCP 443만 있는지 확인한다.
4. rollback은 이 UUID만 disable → apply → delete → apply 순으로 한다.

관리면 이상에는 broad rule을 만들거나 자동 교정하지 않는다. OOB console에서 직전
OPNsense revision을 복원한다.

## 2026-08-01 적용·rollback·영속 증거

- 첫 적용은 Keycloak Pod `0/1 Ready`·`sso` 503으로 Dex 복구와 rule 제거까지 수행했다.
  이 rollback은 백업 복원과 Owner Authorization Code 로그인까지 실제 성공했고, OPNsense
  일반 drift도 통과했다. 같은 복구를 두 번째 적용 중에도 반복해 절차의 재현성을 확인했다.
- 최종 적용 직전 raw config를 저장소 밖 mode 0700 디렉터리에 mode 0600으로 보관했다.
  SHA-256은 `0f83baef9235c1a01c8b05446449ed300a570c7748644ccd2db98d47576095bc`다.
- 최종 rule UUID는 위 표의 `6bcca3bc-b23f-4713-987f-dd4c34790f8a`다. 비활성 생성 뒤 API readback은
  `opt4/in/inet/TCP/10.10.40.10/10.10.20.10/https/pass/keep/log/1216`과 description이
  계획과 정확히 일치했다. enable·apply 뒤 PF runtime에서는 RFC1918 BLOCK 바로 앞 `@112`에
  같은 UUID로 로드됐다.
- OPNsense 재부팅 뒤에도 같은 UUID와 순서가 유지됐다. `netbird-01` issuer discovery TLS 200에서
  PASS counter는 evaluations 7, packets 68, state 1이었고, 같은 출발지 TCP 444 timeout에서
  기존 RFC1918 BLOCK은 evaluations 5, packets 5였다. 다른 source·destination·port는 추가하지
  않았고 최종 일반 drift가 없다.
- 재부팅 중 OPNsense가 k3s 노드의 유일한 upstream resolver라 Keycloak의 PostgreSQL FQDN 해석이
  잠시 실패했다. Keycloak은 Pod restart 없이 약 10분 9초 뒤 `1/1 Ready`와 issuer 200으로 자동
  복구됐고, 그 뒤 DMZ discovery와 NetBird 그룹 허용 200·비그룹 401을 다시 확인했다. 이는 rule
  영속 실패가 아니라 OPNsense 재부팅에 따른 DNS 단일 의존성의 운영 중단 시간으로 기록한다.
