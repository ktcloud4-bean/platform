# ADR-0009: Proxmox 관리 TLS는 네이티브 ACME DNS-01로 분리

- 상태: `Accepted`
- 날짜: 2026-07-30
- 관련 작업: `PVE-ACME-01`, `VM-01`

## 배경

Proxmox 설치 직후의 8006은 PVE Cluster Manager CA가 서명한 인증서를 사용한다. 암호화는 되지만 관리 클라이언트가 이 CA를 별도로 신뢰하지 않으면 서버 신원을 검증할 수 없어 브라우저와 OpenTofu가 경고 또는 검증 우회를 요구한다.

관리 이름은 내부 DNS에서만 주소를 응답하는 canonical FQDN이다. 관리 UI를 인터넷에 공개하거나 443 reverse proxy를 추가하지 않고도, 공개 DNS zone의 DNS-01 challenge로 공인 인증서를 받을 수 있다. OPNsense에는 같은 zone의 wildcard 인증서가 있지만 그 개인키를 복사하면 장비 간 권한·갱신·폐기 경계가 결합된다. 향후 Vault PKI는 내부 TLS와 mTLS용이며 Proxmox 복구보다 늦게 올라오므로 Day 1 관리 인증서의 선행 의존성으로 삼을 수 없다.

## 결정

Proxmox VE 내장 ACME 기능의 Let's Encrypt staging·production endpoint와 Cloudflare DNS API plugin을 사용해 `ip-plan.md`의 Proxmox canonical FQDN 하나만 포함한 인증서를 발급한다. ACME account와 DNS plugin은 cluster 범위, 인증서 domain은 node 범위라는 Proxmox 모델을 유지한다. 관리 endpoint는 HTTPS 8006을 그대로 쓰며 public A/AAAA, NAT, reverse proxy와 443 listener를 만들지 않는다.

OPNsense wildcard 인증서와 개인키를 가져오지 않고 Proxmox가 자신의 ACME account, 인증서와 개인키를 소유한다. wildcard 대신 정확한 node FQDN만 요청한다. OPNsense, Proxmox와 k3s ingress는 같은 공개 zone을 사용해도 DNS API token과 인증서 private key를 각각 분리한다.

Cloudflare에는 이 작업 전용 API token을 만들고 대상 zone 하나의 DNS record 조회·생성·삭제에 필요한 최소 권한만 준다. account 전체 Global API Key와 OPNsense token은 재사용하지 않는다. 현재 Proxmox가 사용하는 upstream DNS plugin의 공식 입력 이름과 요구 권한은 실행 시 설치된 버전에서 다시 확인한다. DNS provider credential은 자동 갱신을 위해 Proxmox의 보호된 ACME plugin config에 남지만 Git, ISO, answer file, shell history, 명령 인자와 일반 로그에는 남기지 않는다.

재현성은 ACME 비밀을 설치 ISO에 넣는 방식이 아니다. `PVE-ACME-01`이 비밀 없는 입력 계약과 검증 절차를 `infra/proxmox/acme/`에 만들고, 실제 값은 구성요소 전용의 Git 제외·mode `0600` 입력으로 설치 후 주입한다. staging으로 DNS challenge와 기본 PVE 인증서 복귀 경로를 먼저 검증한 뒤 production 인증서를 주문한다.

공인 인증서와 strict TLS가 라이브에서 검증된 뒤에만 OpenTofu의 `proxmox_insecure` 기본값을 `false`로 바꾼다. `VM-01`의 첫 apply는 인증서 검증 우회가 제거된 상태만 허용한다.

## 검토한 대안

- **PVE Cluster Manager CA를 모든 client에 배포:** 외부 DNS 자격증명이 필요 없지만 브라우저·워크스테이션·자동화 실행기마다 trust store 수명주기를 운영해야 한다. 소규모 랩에서도 새 client가 검증을 우회하기 쉬워 현재 기준으로 채택하지 않는다.
- **OPNsense wildcard 인증서 복사:** 즉시 경고를 없앨 수 있지만 하나의 private key 유출과 갱신 실패가 두 베어메탈 관리면에 동시에 영향을 준다. 장비별 소유권과 폐기 경계를 위해 거부한다.
- **Vault PKI 사설 인증서:** 내부 workload mTLS에는 적합하지만 client trust 배포가 필요하고 Vault 장애·seal·클러스터 복구가 Proxmox 관리보다 선행하는 순환 의존이 생긴다.
- **443 reverse proxy로 8006을 감춤:** 포트 번호는 인증서 신뢰와 무관하다. 관리면에 별도 proxy와 장애 지점을 추가하므로 사용하지 않는다.
- **http-01:** 관리 주소를 인터넷에서 port 80으로 도달 가능하게 해야 한다. 내부 전용 관리면에는 DNS-01이 더 작은 노출을 만든다.

## 결과

- 브라우저와 OpenTofu는 canonical FQDN과 시스템 trust store로 8006 서버 신원을 검증한다.
- ACME 발급은 관리 endpoint를 공개하지 않지만, 인증서 투명성 로그에는 canonical hostname이 공개될 수 있다. 이 hostname 공개는 수용하되 내부 IP나 관리 경로 공개로 해석하지 않는다.
- Cloudflare token은 Proxmox 안에 지속되는 bootstrap secret이므로 최소 권한·독립 회전·폐기와 로그 마스킹 대상이다.
- DNS-01이 만드는 `_acme-challenge` TXT는 임시 검증 데이터이며 발급 후 잔여 record가 없어야 한다.
- Vault 도입 후에도 Proxmox 관리 인증서를 자동으로 사설 CA로 옮기지 않는다. 별도 client trust 운영과 복구 의존성을 정당화하는 새 ADR이 있을 때만 재검토한다.

## 재검토 조건

- 공개 CT log에 canonical hostname을 남길 수 없게 된다.
- Cloudflare zone보다 더 좁은 DNS update 경계가 필요해 challenge alias용 별도 zone을 운영한다.
- 모든 관리 client의 사설 CA trust 배포·회수·복구가 자동화된다.
- Proxmox의 ACME plugin 저장·갱신 모델 또는 지원 provider가 바뀐다.
- 다중 Proxmox cluster를 도입해 account와 DNS token의 blast radius를 다시 나눠야 한다.

## 구현 기준

- [Proxmox VE Administration Guide - Certificate Management](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
- [acme.sh Cloudflare DNS plugin](https://github.com/acmesh-official/acme.sh/blob/master/dnsapi/dns_cf.sh)
- [Cloudflare API token 생성](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Cloudflare DNS record API](https://developers.cloudflare.com/api/resources/dns/subresources/records/)
