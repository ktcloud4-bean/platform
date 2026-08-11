# packaged Traefik ingress 기준선

이 디렉터리는 `INGRESS-01`이 k3s packaged Traefik에 더하는 `HelmChartConfig`와
`TRAEFIK-METRICS`의 private `traefik-metrics` Service만 소유한다. k3s가 생성하는
`HelmChart traefik`과 `/var/lib/rancher/k3s/server/manifests/traefik.yaml`은 직접 수정하지 않는다.

## 현재 선언 단계

현재 manifest는 live 검증을 통과한 production 기준선이다.

- 기존 단일 Traefik과 ServiceLB를 유지한다.
- `externalTrafficPolicy: Local`로 직접 유입 source IP 보존 기준을 세운다.
- forwarded header의 `insecure` 신뢰를 끄고 trusted proxy를 0개로 시작한다.
- 헤더 값을 버리는 JSON access log로 Traefik이 관측한 `ClientHost`를 검증한다.
- HTTP `web` 요청을 permanent `301`로 HTTPS `websecure`에 redirect한다.
- `k3s-01.imcherry5778.xyz`에 production resolver를 사용하고, `local-path` 128Mi PVC의
  서로 다른 파일에 staging과 production ACME 상태를 둔다. 승격 뒤 staging 상태는
  0바이트로 정리하고 production 상태만 유지한다.
- DNS challenge resolver를 별도로 덮어쓰지 않고 Pod의 `/etc/resolv.conf`가 제공하는
  CoreDNS 경계를 사용한다. PLATFORM Pod에서 직접 공개 UDP 53을 열지 않는다.
- 공개 authoritative DNS 53은 의도적으로 차단돼 있으므로 Traefik 3.7의
  `disableANSChecks`로 그 직접 propagation check만 생략하고, `requireAllRNS`로 Pod가
  사용하는 모든 recursive resolver(CoreDNS 1개)의 TXT 응답은 계속 확인한다. 전체
  propagation check를 끄지 않는다.
- 저장소의 서명된 Git 운영자 identity와 같은 `imcherry5778@gmail.com`을 두 ACME
  account의 contact로 사용한다.
- Cloudflare token은 저장소 밖 mode `0600` 파일 `$KTC_SECRET_ROOT/ingress/env`에서
  `kube-system/ingress-01-cloudflare-dns` Secret으로 주입한다. 형식 계약은 아래
  「적용 gate」가 소유하며 manifest에는 Secret 이름과 key 이름만 둔다.

`CROWDSEC-FIX-01`은 이 소유 경계 안에서 지원되는 같은 `HelmChartConfig`에 community
bouncer의 고정 module/version/archive hash와 read-only key mount만 추가한다. 이는 전역
정적 등록이라 유일한 Traefik Pod를 한 번 교체하지만, middleware attach는
`crowdsec-01` 내부 test route 하나로 제한한다. 기존 entrypoint, ACME, Service,
forwarded header와 인증서 값은 바꾸지 않는다. ADR-0012의 별도 승인과 KC-01 시점 조율 전
적용하지 않으며, 실패 시 enablement commit을 revert해 plugin registration과 이 secret
mount만 제거하고 같은 packaged image와 이 문서의 production 기준선을 회복한다. 비밀이
없는 `AppProject/crowdsec` 기반은 rollback 뒤에도 남겨 child Application finalizer가
namespace를 정상 prune할 수 있게 한다.

`TRAEFIK-METRICS`는 이미 실행 중인 `metrics:9100` entrypoint를 외부 serving Service와
분리한다. `traefik-metrics`는 Traefik Pod만 선택하는 ClusterIP Service이므로 ServiceLB·공개
DNS·NAT에 TCP 9100을 추가하지 않는다. Prometheus의 router drill-down에 필요한
`metrics.prometheus.addRoutersLabels: true`만 HelmChartConfig에 명시하며, header label은
설정하지 않는다. 이 static 설정 변경은 Traefik Pod 한 번의 교체를 수반할 수 있으므로
`TRAEFIK-LIVE`와 immutable Argo 검증·rollback 안에서만 적용한다.

정확한 hostname은 [`docs/ip-plan.md`](../../../docs/ip-plan.md)의 canonical
`k3s-01.imcherry5778.xyz` 하나다. production 인증서가 있어도 public A/AAAA와 NAT는
없으며, 외부 공개는 `EDGE-01` 전까지 열지 않는다.

## 적용 gate

다음을 모두 보고하고 승인받기 전에는 Secret 생성, `platform-root` revision 전환,
DNS-01 staging 또는 production 요청을 실행하지 않는다.

1. `LIVE-GITOPS-READY`: 최신 `origin/main`, 다른 worktree의 `gitops/root/` 변경,
   Argo CD 현재 revision과 이 branch의 signed commit을 대조한다.
2. Cloudflare token은 `imcherry5778.xyz` zone 하나에 대한 `Zone:Read`와
   `DNS:Edit`만 가지며 OPNsense·Proxmox token을 복사하지 않는다.
3. 내부 A는 `10.10.20.10`, 외부 authoritative A/AAAA는 NXDOMAIN을 유지하고,
   DNS-01은 임시 `_acme-challenge.k3s-01.imcherry5778.xyz` TXT만 만든다.
4. staging 성공과 TXT 정리를 확인한 뒤 production 발급을 별도 승인받는다.

Secret 주입은 승인 뒤에만
[`gitops/tools/ingress-01/inject-cloudflare-secret.sh`](../../tools/ingress-01/inject-cloudflare-secret.sh)를
사용한다. 스크립트는 env 파일을 `source`하지 않고 `CLOUDFLARE_API_TOKEN` 한 항목만
읽는다. 기본 입력은 저장소 밖의 `~/secrets/ktcloud4-bean/ingress/env`이며 mode
`0600`으로 유지한다. token 값, Secret YAML, ACME account와 private key를 출력하지
않는다.

```bash
S="${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/ingress"
install -d -m 700 "$S"
umask 077
cat >"$S/env" <<'EOF'
CLOUDFLARE_API_TOKEN=
EOF
# imcherry5778.xyz zone 한정 Zone Read + DNS Write 권한의 k3s Traefik 전용 token.
# 주석과 CLOUDFLARE_API_TOKEN 한 항목만 허용한다.
```

편집 뒤에는 token을 채팅·셸 명령 인자에 넣지 않고 다음처럼 실행한다.

```bash
K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
K3S_SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
./gitops/tools/ingress-01/inject-cloudflare-secret.sh
```

`.gitignore`는 실수 커밋만 막을 뿐이고 `git clean -xfd`와 worktree 정리는 저장소 안
파일을 지운다. 그래서 `SECRET-01` 이후 실제 token은 저장소 안에 두지 않고
`~/secrets/ktcloud4-bean/ingress/env` 하나만 원본으로 유지한다. worktree를 오가며
복사하지 않으므로 merge 뒤 파일을 옮기는 절차도 필요하지 않다.

## task commit과 main 전환

live 검증 동안 child Application은 mutable branch가 아니라 검증할 선언 commit SHA를
읽는다. 먼저 설정 commit을 만든 뒤 다음 signed commit에서 `targetRevision`을 그 SHA로
갱신한다. `platform-root`는 pointer 갱신 commit, `ingress` Application은 설정 commit과
각각 실제 revision이 일치해야 한다. production 변경도 같은 두 commit 순서를 반복한다.

최종 검증 뒤 `targetRevision`을 `main`으로 바꿔 squash merge하고, `platform-root`를 최신
main으로 전환한 뒤 두 Application을 다시 검증한다.

## production 승격

staging 검증 뒤 같은 `HelmChartConfig`에 다음 두 값을 추가해 별도 signed commit으로
검증했다.

- `ports.web.http.redirections.entryPoint`: `websecure`, `https`, permanent
- `ports.websecure.http.tls`: production resolver와
  `k3s-01.imcherry5778.xyz` domain

production 발급·strict TLS·redirect·source IP·Pod restart·Argo drift와 정리를 모두
통과한 뒤 백로그를 `DONE`으로 바꿨다.

## 2026-07-31 staging 중단 증거

Cloudflare/public DNS staging 승인 뒤 임시 `ingress-01-verify` namespace와 digest 고정
echo workload로 두 번 검증했지만 인증서 발급 전 zone discovery에서 중단했다.

- 공개 resolver `1.1.1.1:53`, `1.0.0.1:53`은 Traefik Pod에서 timeout이었다.
- Pod의 CoreDNS와 PLATFORM gateway DNS는 도달 가능했지만 split zone
  `imcherry5778.xyz`의 SOA·NS를 NODATA로 반환했다. lego는 상위 `xyz.`를 zone으로
  오판해 TXT 생성 전에 중단했다.
- 외부 TCP 53·853은 차단되고 HTTPS 443만 허용됐다. 제거된 `cloudflared proxy-dns`나
  임의 DoH sidecar를 승인 없이 추가하지 않았다.
- `_acme-challenge.k3s-01.imcherry5778.xyz` TXT는 생성되지 않았고 최종 부재를
  authoritative resolver에서 확인했다. production ACME 파일은 0바이트를 유지했다.
- 정상 요청과 `X-Forwarded-For: 203.0.113.77` 위조 요청 모두 Traefik
  `ClientHost=10.10.60.2`, backend `X-Real-Ip`·`X-Forwarded-For=10.10.60.2`였다.
  실행 host route source `100.64.0.1`은 Traefik 앞 tunnel/NAT에서 변환되는 경계다.
- 임시 namespace를 제거하고 `platform-root`를 검증 전 main revision으로 되돌렸다.
  당시 child Application에 finalizer가 없어 orphan된 정확한 `HelmChartConfig/traefik`을
  삭제한 뒤 packaged 기본값과 ServiceLB를 확인했다. Secret과 128Mi PVC는 rollback
  계약에 따라 보존했다.

`OPNSENSE-LIVE` 잠금 아래 공인 apex 전체를 Dnsmasq로 보내던 query-forward row를
비활성화해 이 blocker를 교정했다. 내부 canonical A/PTR·alias는 유지됐고 내부
resolver와 CoreDNS 경유 Pod에서 공개 SOA·NS가 Cloudflare authoritative 결과와
일치했다. 외부 DNS 53 차단은 유지하므로 다음 staging은 recursive CoreDNS 검사만
유지하고 authoritative 직접 검사를 생략하는 선언으로 다시 검증한다.

## 2026-07-31 staging 재검증 성공

교정 뒤 packaged Traefik `3.7.4` 하나와 기존 imageID를 유지한 채 staging DNS-01을
재검증했다. 첫 요청은 Cloudflare authoritative NS에 TXT를 만들었지만 API 쓰기 직후의
최초 recursive 조회가 아직 NXDOMAIN인 NS에 닿아 Unbound가 SOA MINIMUM 1800초 동안
negative cache했고, Traefik의 propagation 제한을 넘겼다. 전역 Unbound cache 정책은
바꾸지 않고 두 ACME resolver에 공식 `propagation.delayBeforeChecks: 30s`를 추가해
최초 조회 전에 Cloudflare 전파 시간을 확보했다. 이미 남은 실패 cache만 정확한
`_acme-challenge.k3s-01.imcherry5778.xyz` TXT type으로 한 번 flush한 뒤 재시도했으며,
이는 운영 갱신 절차나 지속 설정이 아니다.

- 두 Cloudflare authoritative NS에서 TXT `0 → 1 → 0`을 값 없이 관측했고 최종 0개다.
- staging leaf의 SAN은 `k3s-01.imcherry5778.xyz`, issuer는 Let's Encrypt staging이며
  2026-07-31부터 2026-10-29까지 유효하다. 올바른 hostname은 일치하고 잘못된 hostname은
  실패했으며, system trust가 staging CA를 거부하는 것도 확인했다.
- 실행 host의 route source `100.64.0.1`은 Traefik 앞 tunnel/NAT에서 `10.10.60.2`로
  변환된다. 정상·위조 XFF 요청 모두 Traefik `ClientHost`와 backend X-Real-IP/XFF가
  `10.10.60.2`였고 임의 `203.0.113.77`은 신뢰되지 않았다.
- 인증서 발급 뒤 Traefik Pod를 교체해 같은 인증서 fingerprint와 HTTPS 200을 확인했다.
  staging ACME 파일은 크기와 mtime이 유지됐고 production 파일은 0바이트, 재기동 중
  challenge TXT도 계속 0개였다.
- root와 ingress Application은 각각 검증 pointer·설정 commit과 일치한
  `Synced/Healthy`이며 live HelmChartConfig와 Git 값의 SHA-256이 같다. Traefik과
  ServiceLB는 각각 하나, Node Ready와 DiskPressure 없음, 전체 비정상 Pod 0개,
  k3s active, failed unit 0개, 루트 파일시스템 사용률 4%를 확인했다.

ingress 전용 token은 live Secret과 일치하고 이 branch의 Git 이력·diff에는 없다. 최신
main의 NB-01 Ansible defaults에 있던 이 token과 다른 `cfat_` 형식 값은 production 요청
전에 사용자가 Cloudflare에서 폐기했다. INGRESS-01은 이 범위 밖 credential을 사용하거나
임의 수정하지 않았다.

## 2026-07-31 production 검증 성공

- 같은 SAN의 staging 인증서가 Traefik 전역 TLS store에 남으면 production resolver가
  요청되지 않는 동작을 확인했다. 폐기 가능한 staging ACME 파일 하나만 0바이트로 정리하고
  Pod를 교체한 뒤, production resolver를 명시한 임시 IngressRoute로 발급했다.
- 두 Cloudflare authoritative NS에서 production TXT `0 → 1 → 0`을 값 없이 관측했다.
  최종 public A·AAAA·TXT는 모두 0개이며 내부 A만 `10.10.20.10`이다.
- leaf SAN은 `k3s-01.imcherry5778.xyz`, issuer는 Let's Encrypt `YR1`, 유효기간은
  2026-07-31부터 2026-10-29까지다. system strict TLS가 성공하고 잘못된 hostname은
  curl 60으로 실패했으며 leaf·intermediate·root chain 3장을 제공한다.
- HTTP는 `301 Moved Permanently`와 원래 path/query를 보존한 정확한 HTTPS Location을
  반환한다. public A/AAAA·NAT·origin은 만들지 않았다.
- 정상·위조 XFF 요청 모두 Traefik `ClientHost`와 backend X-Real-IP/XFF가
  `10.10.60.2`이고 임의 `203.0.113.77`은 제거됐다. 실행 host의 route source
  `100.64.0.1`은 Traefik 앞 tunnel/NAT 경계에서 변환된다.
- production 발급 뒤 Pod를 교체해 같은 certificate fingerprint, strict HTTPS 200과
  redirect를 확인했다. 재기동 중 TXT는 계속 0개였고 production ACME 파일의 크기와
  mtime도 같았다.
- k3s·OPNsense·Proxmox가 제공하는 인증서의 public key는 서로 다르다. ingress private
  key는 mode `0600` PVC ACME 파일에만 있고 Kubernetes TLS Secret으로 복사하지 않았다.
- root/ingress Application revision 일치와 `Synced/Healthy`, Git/live HelmChartConfig
  SHA-256 일치, Traefik·IngressClass·ServiceLB 각각 하나, 전체 비정상 Pod 0개,
  Node Ready·DiskPressure 없음, k3s active, failed unit 0개, 디스크 사용률 4%를 확인했다.
- 임시 namespace, challenge TXT, 테스트 record와 port-forward는 모두 제거했다.

## rollback

설정 rollback은 `platform-root`를 production 전 pointer
`b3da1a0af628fb8a27bb398d70f78d0c70a34335`로 되돌려 redirect와 기본 production TLS
domain을 제거한다. production ACME 파일은 자동 삭제하지 않으므로 동일 SAN 인증서가
전역 store에서 계속 선택될 수 있다. serving까지 중단해야 할 때만 production ACME 파일
하나를 0바이트로 정리하고 Traefik Pod를 교체하며, 이미 발급된 인증서의 CA revoke는
별도 절차다. Secret·PVC·OPNsense·Proxmox·k3s uninstall과 다른 namespace는 rollback
대상이 아니다.

Unbound 교정 rollback이 별도로 필요하면 비활성화한
`imcherry5778.xyz → 127.0.0.1:53053` query-forward row만 다시 활성화하고 Unbound를
재구성한다. 이 rollback은 공개 SOA·NS를 다시 가리므로 ingress ACME를 먼저 packaged
기본값으로 복구한 뒤 수행한다. PF·NAT·DHCP와 OPNsense 인증서는 건드리지 않는다.
