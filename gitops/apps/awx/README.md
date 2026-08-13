# AWX GitOps 자동화 경계

이 디렉터리는 `AWX-01`의 AWX Operator `2.19.1`과 AWX `24.6.1` 선언을
소유한다. 이미지는 `release-metadata.env`의 OCI index digest로 고정한다. Operator의
CRD·Role·RoleBinding·manager는 upstream tag의 파일을 `operator/vendor/`에 그대로
vendoring했고, 사용하지 않는 metrics auth proxy와 폐기된 pull secret만 제외했다.

## 배치와 데이터 경계

- `AWX/awx`는 web 1, task 1, EE, redis 한 세트만 만든다. resource request 합계는
  AWX control plane 기준 약 3 GiB이고 각 container limit을 명시한다.
- PostgreSQL Pod와 PVC는 만들지 않는다. `postgres-01.imcherry5778.xyz:5432`의
  전용 `awx` DB·`awx_user`에만 연결하며 `sslmode=verify-full`과 PG-01 공개 leaf를 쓴다.
- projects PVC와 별도 SCM credential을 만들지 않는다. 검증 playbook은 GitOps ConfigMap을
  web/task의 manual project 경로에 read-only mount해 공급한다. private 저장소 접근용
  credential을 AWX에 복제하거나 Argo CD credential을 재사용하지 않는다.
- 배포 직전과 직후에는 `docs/capacity-plan.md`의 `k3s-01` guest available을 읽는다.
  12 GiB 경고선까지 여유가 없으면 적용을 시작하거나 계속하지 않는다.

## Secret 소비 경계

사람 입력의 단일 위치는 `$KTC_SECRET_ROOT/awx/env`(mode `0600`)이다. 저장소 안
`.env`, cluster-wide injector, CSI, Secret 동기화 operator는 사용하지 않는다.
`prepare-secret-input.sh`는 파일이 없을 때만 값을 만들고 기존 입력을 덮어쓰지 않는다.

각 workload는 audience가 `vault`인 600초 projected ServiceAccount token과 명시적
Vault Agent init container를 쓴다. Vault KV v2의 원본 경로는
`kv/awx/runtime` 하나다. stock AWX Operator는 external PostgreSQL, admin password,
secret key, bundle CA를 Kubernetes Secret 참조로만 받을 수 있으므로
`awx-secret-bootstrap` Sync hook이 Vault 원본으로부터 그 네 개의 namespace runtime
Secret을 한 번 materialize한다. 이는 지속 동기화 controller가 아니며 Secret 값은 Git,
Job 로그, 명령 인자에 넣지 않는다. Operator가 추가로 관리하는 runtime Secret도 Git에
선언하지 않는다.

## 인증과 최소권한 RBAC

브라우저 경로는 다음 두 판정을 모두 통과해야 한다.

```text
Browser -> Traefik -> Pomerium claim/groups -> AWX Generic OIDC -> Keycloak
        -> AWX organization/team/object role
```

Pomerium Route에는 `/platform-users`, `/platform-privileged`의 정확한
`claim/groups`만 있고 인증 사용자·email·domain fallback이 없다. Keycloak `awx`
confidential client는 Authorization Code만 허용하고 groups mapper를 쓴다. AWX social
auth callback이 외부 alias로 고정되도록 AWX Route만 원래 Host를 보존한다. mapping은
다음과 같다.

POL-01 기본 deny 아래 Pomerium server Pod의 egress는 `awx-web` Pod TCP 8052 하나만
추가 허용한다. 이는 cluster 내부 AWX web upstream 경로이며 VLAN 간 SSH 22나 다른
OPNsense 경로를 열지 않는다.

| Keycloak 사용자 | 그룹 | AWX team | 허용 |
|---|---|---|---|
| `imcherry5778` | `/platform-users` | `AWX Operators` | 검증 inventory use, 허용 credential use, check 실행, 승인 workflow 시작 |
| `imcherry5778-admin` | `/platform-privileged` | `AWX Approvers` | workflow approval |

두 팀 모두 AWX superuser나 organization admin이 아니다. `AWX Operators`에는 운영 VM
inventory, 음성 대조 credential/template, apply Job Template 권한을 부여하지 않는다.
기본 Job Template은 고정 `job_type=check`이며 launch 때 run으로 바꿀 수 없다. apply
template은 approval node 성공 뒤 workflow 내부에서만 실행된다.

Keycloak/Pomerium/OIDC 장애 때는 trusted SSH로 k3s에 접속해
`kubectl -n awx port-forward svc/awx-service 18080:80`을 연 뒤, 저장소 밖 입력과
Vault가 소유하는 `awx-recovery` 로컬 admin으로 `http://127.0.0.1:18080`에 접근한다.
이 계정은 일상 SSO에 쓰지 않는다. 비밀번호를 교체할 때는 별도 credential 교체 승인을
받고 Vault 원본과 runtime Secret을 함께 다룬다.

## 정적 inventory와 선택지 (b) 한계

`운영 VM 정적 인벤토리 (실행 금지)`는 `docs/ip-plan.md`의 고정 VM canonical FQDN만
선언하며 NetBox나 다른 동적 inventory source를 만들지 않는다. VLAN 20에서 다른 VLAN의
SSH 22는 `NET-03` 기본 deny 아래 열려 있지 않다. 이 작업에서는 사용자가 선택한
**(b)**에 따라 OPNsense 방화벽을 바꾸지 않고, 운영 inventory에는 credential·use/execute
role을 할당하지 않는다. 운영 대상의 최소 통신표와 SSH 허용은 `NET-04`가 소유한다.

완료 증거용 `AWX-01 검증 전용 (cluster 내부)` inventory는
`awx-verifier.awx.svc.cluster.local` 하나만 포함한다. allow/deny credential 대조와 승인
workflow가 이 대상에 보내는 요청은 read-only HTTP GET뿐이다. 따라서 이 증거는
**실제 운영 대상의 cross-VLAN 접근 증거가 아니다**. 실제 VM job 실행 가능 판정은
`NET-04` 이후 별도 소유 경계에서 해야 한다.

## 완료 증거 (2026-08-02 16:11 KST)

1. inventory: 운영 정적 host 5대가 `docs/ip-plan.md`와 일치하고 dynamic source는 0건이다.
   검증 inventory는 내부 verifier 1대뿐이며 세 Job Template의 inventory·limit이 정확히
   고정됐다.
2. credential 격리: `2026-08-02T07:11:48.998Z`에 최소권한 credential의 job `9`가
   성공했고, 같은 operator의 미할당 template·credential 접근은 각각 403이었다. Git,
   AWX Pod 로그, job stdout에서 비밀 원문은 모두 0건이었다.
3. 승인 경계: operator의 apply 직접 실행과 approval은 403이었고, privileged approver의
   사람 승인 뒤 workflow `10`과 apply node만 성공했다.
4. capacity: 최종 배포 직전 guest available 17,970 MiB에서 적용을 시작했고, 직후
   `k3s-01` guest available 15,598 MiB·swap 0·root 8%로 **GO**를 판정했다.

위 job 실행은 모두 `awx-verifier.awx.svc.cluster.local`의 read-only HTTP GET이다. 선택지
(b)에 따른 이 결과는 **실제 운영 대상의 cross-VLAN 접근 증거가 아니다**.

## AWX-02 non-root와 신규 ID 경계

AWX Operator `2.19.1`의 `security_context_settings`는 web/task Pod에만 렌더링된다. AWX와
EE image는 UID 1000이지만 Redis image는 OCI `USER`가 비어 있으므로 `runAsNonRoot: true`만
선언하면 kubelet이 Redis를 시작하지 못한다. 따라서 web/task는 Pod 수준 UID 1000과 fsGroup
1000, RuntimeDefault seccomp를 고정한다. AWX image의 시작 스크립트는 upstream image가
group 0 write로 준비한 `/etc/passwd`, supervisor, rsyslog 경로를 사용하므로 primary GID는
기존 image contract와 같은 0을 유지한다. 모든 container의 UID는 1000이며 root user로
실행되지 않는다. Operator reconciliation이 이 선언으로 Deployment와 Pod를 다시 만들며
개별 container에 중복 선언하지 않는다.

AWX default container group는 별도 `automation-job-*` Pod를 만든다. 이 경로는 CR의 web/task
`security_context_settings`와 migration Job mutation 어느 쪽도 상속하지 않는다. 따라서 CR의
read-only `DEFAULT_EXECUTION_QUEUE_POD_SPEC_OVERRIDE`에 같은 Pod security context를 선언한다.
생성 Pod 이름·label을 넓게 admission mutation하지 않으며, 실제 check/apply 실행이 이 선언과
Enforce 정책의 결합 증거다.

별도 `awx-migration-*` Job template은 이 CR 필드를 상속하지 않는다. 정책 child의
`pol-02-awx-migration-run-as-non-root`는 `awx` namespace, `Job/awx-migration-*`,
`component=awx`와 `managed-by=awx-operator`가 모두 일치하는 CREATE admission에만 같은 Pod
security context를 주입한다. 범위 밖 Job은 기존 Enforce 정책이 계속 거부한다. 이 두 경로가
준비된 뒤 만료형 `pol-02-awx-run-as-non-root` 예외를 제거한다.

SSO mapping의 현재 exact set은 일상 `imcherry5778` → `Platform/AWX Operators`, 특권
`imcherry5778-admin` → `Platform/AWX Approvers`다. 두 계정의 최초 SSO가 AWX user와 membership을
만들며 legacy user의 잔존 Organization/Team membership은 허용하지 않는다. 두 team에 부여할
object role도 provision Job이 allowlist 밖 role을 제거해 수렴한다. 어느 계정도 superuser나
Organization admin이 아니다.

`gitops/tools/awx-02/verify-live.sh platform`은 CR·web/task·migration admission·예외 제거와
root/AWX/policy child를 한 번 판정한다. `identity-state`는 두 사람의 첫 SSO 뒤 exact membership을,
`browser-rbac`은 사람이 제공한 현재 MFA 입력으로 금지 API의 실제 403을 판정한다. `secrets`는
사람 세션 없이 Git 추적 파일과 현재 AWX Pod 로그의 secret 원문 0건을 판정한다. 사람의 첫
로그인과 MFA를 서버 측 검증기가 대신하지 않는다.

Rollback은 policy-baseline child를 시작 main SHA로 먼저 돌려 mutation 제거와 만료형 AWX
예외 복원을 확인한 다음 AWX child를 같은 SHA로 돌려 CR의 `security_context_settings`를 제거한다.
Operator가 기존 web/task spec을 복구하고 둘 다 Ready가 되면 root와 두 child를 literal `main`으로
복원한다. AWX CR·DB·PVC·runtime Secret은 삭제하지 않는다.

## 적용 순서와 검증

1. `prepare-secret-input.sh`, `provision.sh --check`, `provision.sh --apply`로 DB,
   Keycloak client와 Vault 객체를 신규 구성한다. 기존 credential 차이는 자동 교체하지 않는다.
2. OPNsense `awx -> k3s-01` alias는 `opnsense-alias.py check` 뒤 별도 승인을 받고
   `apply`한다. 이어 `infra/opnsense/scripts/check-drift.sh --update`로 snapshot을 갱신한다.
3. `AGENTS.md`의 `ARGO-ROOT` 잠금 아래 root/child를 rebase된 commit SHA로 고정하고
   `verify-live.sh`로 백로그의 네 증거만 판정한다. 실패하면 Operator 로그와 AWX CR
   status를 먼저 읽어 RAM, DB, image 중 실패 지점을 구분한다.
4. root/child를 기록한 main SHA로 되돌린다. 최종 Application `targetRevision`은 `main`이다.

실제 VM 구성 변경 playbook apply, 성능·부하 시험, 재부팅 drill, Traefik 재기동은 이
검증에 포함하지 않는다.
