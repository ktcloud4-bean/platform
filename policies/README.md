# POL-01/POL-02 정책 기준선

이 디렉터리는 Kyverno Enforce 정책 한 건과 `pomerium` namespace NetworkPolicy 기준선을
소유한다. Kyverno controller 배포와 버전·digest·검증/rollback 경계는
[`gitops/apps/kyverno/README.md`](../gitops/apps/kyverno/README.md)가 소유한다.

`POL-02`는 `POL-01`에서 Audit한 Pod-level `runAsNonRoot` 규칙 한 건만 `Enforce`로
승격한다. 적용 전 PolicyReport에서 확인한 `argocd`, `awx`, `crowdsec-01`, `velero`의 기존
workload만 정확한 kind·이름·policy rule로 예외 처리한다. 예외는 `kyverno` namespace에서만
인식되며 `2026-09-02T15:00:00Z` 뒤에는 `time_now_utc()` 조건이 거짓이 되어 같은 위반
입력을 admission에서 거부한다. 소유자와 보정 사유는 각 `PolicyException` annotation이
소유한다. background report에는 예외를 적용하지 않아 남은 위반을 숨기지 않는다.

NetworkPolicy는 k3s 내장 kube-router가 실제 강제하므로 새 namespace에 기계적으로 복제하지
않고, 통신표와 대표 경로가 확인된 namespace만 별도 검증 뒤 추가한다.

`REG-01`은 기존 `pomerium` egress allowlist에 Harbor nginx Pod TCP 8080 한 경로만
추가한다. Harbor namespace의 새 default-deny를 함께 만들지는 않는다.

## Keycloak egress 경로

`pomerium` namespace의 두 workload는 모두 Keycloak에 나가야 한다. Pomerium은 OIDC
discovery와 token 교환을, Dashy는 [ADR-0014](../docs/adr/0014-dashy-access-portal.md)의
공개 PKCE client로 받은 토큰의 서명 검증을 각각 수행한다. Dashy의 이 경로는 `POL-01`
default-deny 도입 때 누락돼 포털이 로그인 상태를 유지하지 못했고 `POL-01-FIX-01`이
`pol-01-dashy-required-egress`로 보정했다.

두 정책의 목적지는 Traefik Pod가 아니라 `svclb-traefik` Pod다. 랩 DNS가 `sso` hostname을
노드 IP로 해석하고 그 443은 `hostNetwork`를 쓰지 않는 svclb Pod의 hostPort가 받으므로,
NetworkPolicy는 노드 IP가 아니라 그 Pod를 목적지로 평가한다. Traefik Pod TCP 8443 규칙은
Service ClusterIP를 경유하는 호출만 담당한다. 같은 작업에서 Pomerium의 목적지 없는 443
규칙을 이 경로로 좁혔다. 모든 route upstream이 내부 http Service이므로 그 밖의 외부 443
egress는 필요하지 않다.

## POL-02 적용 결과

- 임시 예외 `pol-02-expiring-exception`은 `2026-08-02T15:27:28Z` 전 정확한 이름에서만
  허용됐고, 범위 밖 이름과 만료 뒤 같은 입력은 admission에서 거부됐다.
- 설정 SHA `106444b8ce399a4e119f6865f20f739718719eee`, root pointer
  `aa688fd80e39d1549ea3c80a4455b813292753c3`에서 기존 signed release digest는 Enforce 상태로
  admission을 통과해 `Running/Ready`가 됐다. 전체 pipeline은 재실행하지 않았다.
- 시작 main `ae2a802ebcc3dd4e2476f962b0f3b467a6cd304d`로 rollback해 ClusterPolicy `Audit`, 관련
  PolicyException 0건, `platform-root`와 `kyverno`·`policy-baseline`·`e2e-01` child의
  `Synced/Healthy`를 확인했다. 최종 child 선언은 `main`이다.
