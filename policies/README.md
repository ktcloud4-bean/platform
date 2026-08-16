# POL-01/POL-02 정책 기준선

이 디렉터리는 Kyverno Enforce 정책 한 건과 `pomerium` namespace NetworkPolicy 기준선을
소유한다. Kyverno controller 배포와 버전·digest·검증/rollback 경계는
[`gitops/apps/kyverno/README.md`](../gitops/apps/kyverno/README.md)가 소유한다.

`POL-02`는 `POL-01`에서 Audit한 Pod-level `runAsNonRoot` 규칙 한 건만 `Enforce`로
승격한다. 적용 전 PolicyReport에서 확인한 `argocd`, `crowdsec-01`, `velero`의 기존
workload만 정확한 kind·이름·policy rule로 예외 처리한다. 이 세 예외는 `kyverno`
namespace에서만 인식되며 `2026-09-02T15:00:00Z` 뒤에는 `time_now_utc()` 조건이 거짓이 되어
같은 위반 입력을 admission에서 거부한다. 소유자와 보정 사유는 각 `PolicyException`
annotation이 소유한다. background report에는 예외를 적용하지 않아 남은 위반을 숨기지
않는다.

`POL-03-FIX-01`은 Velero `node-agent` 예외와 분리해, v1.18.2가 만드는 동적
`PodVolumeBackup` hosting Pod만 별도 허용한다. `velero.io/pod-volume-backup` 라벨 값과
Pod 이름의 일치, `velero.io/v1` `PodVolumeBackup` controller ownerRef, 그리고
`velero-server` ServiceAccount의 요청을 모두 만족해야 한다. 따라서 같은 namespace의
일반 root Pod 및 라벨만 흉내 낸 Pod는 `POL-01`에서 계속 거부된다.

`AWX-02`는 AWX web/task에 Operator CR의 Pod-level non-root 값을 선언하고 기존 만료형 AWX
예외를 제거했다. Operator `2.19.1`이 같은 CR 값을 migration Job에는 전달하지 않으므로,
`pol-02-awx-migration-run-as-non-root` mutation이 정확한 namespace·Job 이름·두 upstream label의
CREATE 요청에만 UID 1000·GID 0·fsGroup 1000과 RuntimeDefault seccomp를 주입한다. GID 0은
AWX image가 group-write로 준비한 시작 경로를 쓰기 위한 upstream runtime contract다. selector가 다르면
mutation하지 않으며 기존 Enforce가 누락된 `runAsNonRoot`를 거부한다.

## Falco root sensor 경계

`CAP-03` cold start 뒤 기존 Falco Pod는 root UID inotify instance `127/128` 고갈로 재기동에
실패했다. `fs.inotify.max_user_instances=256`으로 원인을 제거한 뒤 Pod를 교체하자, 이번에는
POL-02가 새 Pod의 Pod-level `runAsNonRoot` 누락을 admission에서 거부했다. 고정 Falco
`0.44.1` image 자체의 OCI user가 `0`이므로 boolean을 참으로 쓰는 보정은 kubelet 실패를
감출 뿐이다.

Falco는 일반 workload 예외가 아니라 modern eBPF host sensor로 명시한다. 만료 없는 두
`PolicyException`은 `falco` namespace의 `Pod/falco-*`와 `DaemonSet/falco`, 해당 direct·autogen
rule 하나씩만 허용한다. 범위를 넓히는 대신 `pol-02-falco-root-sensor-baseline` Enforce가
고정 image digest·ServiceAccount·token 미자동 mount·비privileged·권한 상승 금지·read-only
rootfs·RuntimeDefault seccomp·네 capability와 세 hostPath만 허용한다. image digest, capability,
hostPath 또는 ServiceAccount를 바꾸면 예외와 보상 정책을 같은 변경에서 재검토한다.

[`verify-falco-recreate.sh`](../gitops/tools/cap-03/verify-falco-recreate.sh)는 준비된 Pod가 있다는
사실만 보지 않는다. 정확한 정책·예외 범위를 먼저 확인하고 API-valid한
`allowPrivilegeEscalation=true` 변형이 보상 정책에서 server dry-run 거부되는지 확인한다. 그
다음 Falco Pod 한 건을 삭제해 새 UID가 120초 안에 Ready가 되는지, `runAsNonRoot` admission
거부 count와 inotify 초기화 오류가 늘지 않는지 판정한다. 이 검증으로 기존 Pod가 Enforce
전부터 남아 결함을 숨기는 경로를 차단한다.

NetworkPolicy는 k3s 내장 kube-router가 실제 강제하므로 새 namespace에 기계적으로 복제하지
않고, 통신표와 대표 경로가 확인된 namespace만 별도 검증 뒤 추가한다.

## Wazuh manager 공급망 예외

`SUPPLY-05-FIX-04`는 기존 Wazuh system 예외가 `docker.io/wazuh/*` 또는
`docker.io/library/python:*` init container만 허용해, 실제 `wazuh-manager-master-0`의
고정 `hashicorp/vault` init image를 재생성 때 거부하던 결함을 보정한다. 범용 Wazuh prefix에
Vault를 추가하지 않고 다음 값을 모두 고정한 별도 조건만 둔다.

- namespace·Pod: `wazuh` / `wazuh-manager-master-0`
- ServiceAccount: `wazuh-manager`
- main container 한 개: 선언된 Wazuh manager exact digest
- init container 한 개: 선언된 Vault exact digest
- ephemeral container: 0개

Pod 이름·ServiceAccount·두 digest·container 수 중 하나라도 다르면 이 예외를 통과하지 않는다.
현재 Enforce/Fail 정책과 rollback Audit/Ignore 정책은 같은 exact 예외를 가져, 장애 전환 때
system lifecycle 판정이 달라지지 않게 한다.

`REG-01`은 기존 `pomerium` egress allowlist에 Harbor nginx Pod TCP 8080 한 경로만
추가한다. Harbor namespace의 새 default-deny를 함께 만들지는 않는다.

## Keycloak egress 경로

`pomerium` namespace의 두 workload는 모두 Keycloak에 나가야 한다. Pomerium은 OIDC
discovery와 token 교환을, Dashy는 [ADR-0014](../docs/adr/0014-dashy-access-portal.md)의
공개 PKCE client로 받은 토큰의 서명 검증을 각각 수행한다. Dashy의 이 경로는 `POL-01`
default-deny 도입 때 누락돼 포털이 로그인 상태를 유지하지 못했고 `POL-01-FIX-01`이
`pol-01-dashy-required-egress`로 보정했다.

이 경로는 목적지를 좁힐 수 없다. 랩 DNS가 `sso` hostname을 k3s 노드 IP로 해석하고 그 443은
`svclb-traefik` Pod의 hostPort가 받는데, `POL-01-FIX-01`에서 svclb `podSelector`와 노드 IP
`ipBlock`을 각각 적용해 실측한 결과 둘 다 차단됐다. 목적 port만 제한할 때 통과했으므로
Pomerium의 기존 443 규칙을 좁히려던 시도는 철회하고 그대로 두었다.

port만 제한한 규칙은 단독으로 두어도 동작하지 않는다. Dashy에 그 규칙 하나만 부여했을 때는
노드 IP 경로가 계속 거부됐고, Traefik Pod TCP 8443 규칙을 함께 둔 뒤에야 통과했다. 같은 경로를
쓰는 Pomerium이 처음부터 동작한 것도 두 규칙을 함께 갖고 있었기 때문이다. 두 workload의 egress
구성을 같게 유지한다. 모든 route upstream이 내부 http Service이므로 그 밖의 외부 443 egress는
필요하지 않다.

## POL-01-FIX-01 검증 결과

- Dashy Pod에서 Keycloak discovery 도달 양성, Dashy 로그의 `token verification failed`
  신규 발생 0건.
- 음성 경계 유지: Dashy → Vault TCP 8200, Dashy → Gitea TCP 3000 모두 차단.
- headless 브라우저 검증에서 `imcherry`의 보호 route 200과 그룹 타일 표시 확인,
  Pomerium error 로그 0건으로 기존 route 회귀 없음.
- 시작 main `30600f43632c`로 rollback해 `platform-root`와 `policy-baseline`의
  `Synced/Healthy`를 확인했다. 최종 child 선언은 `main`이다.

## POL-02 적용 결과

- 임시 예외 `pol-02-expiring-exception`은 `2026-08-02T15:27:28Z` 전 정확한 이름에서만
  허용됐고, 범위 밖 이름과 만료 뒤 같은 입력은 admission에서 거부됐다.
- 설정 SHA `106444b8ce399a4e119f6865f20f739718719eee`, root pointer
  `aa688fd80e39d1549ea3c80a4455b813292753c3`에서 기존 signed release digest는 Enforce 상태로
  admission을 통과해 `Running/Ready`가 됐다. 전체 pipeline은 재실행하지 않았다.
- 시작 main `ae2a802ebcc3dd4e2476f962b0f3b467a6cd304d`로 rollback해 ClusterPolicy `Audit`, 관련
  PolicyException 0건, `platform-root`와 `kyverno`·`policy-baseline`·`e2e-01` child의
  `Synced/Healthy`를 확인했다. 최종 child 선언은 `main`이다.
