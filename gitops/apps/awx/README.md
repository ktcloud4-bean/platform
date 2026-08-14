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

## AWX-03 기본 deny 통신 경계

`awx-default-deny`가 namespace의 ingress·egress를 먼저 막고, `network-policies.yaml`이 현재
확인된 흐름만 다시 허용한다. web/task/migration은 PostgreSQL `10.10.50.10:5432`, web만 내부
Traefik을 통한 Keycloak `443`, task와 provision Hook만 web `8052`, execution Pod만 verifier
`8080`을 사용한다. Vault Agent init는 verifier와 두 Hook에 각각 분리된 selector로 Vault
`8200`만 사용하고, Operator·runtime·execution·bootstrap은 Kubernetes API의 Service `443`과
k3s endpoint `6443`만 사용한다. Pomerium server만 web `8052` ingress 권한을 가진다.

DNS는 CoreDNS TCP/UDP `53`으로만 열며, 외부 VM SSH·임의 RFC1918 egress·공개 DNS/NAT·OPNsense
규칙은 추가하지 않는다. `gitops/tools/awx-03/verify-live.sh`는 선언, 필요 경로와 PostgreSQL
대상 TCP `22` 차단을 판정한다. browser RBAC 검증의 성공 job은 execution Pod→verifier `8080`과
Pomerium→web ingress를 함께 확인한다.

Rollback은 AWX child를 시작 main SHA로 먼저 sync해 NetworkPolicy를 prune하고, web/task Ready를
확인한 다음 root를 literal `main`으로 복원한다. AWX CR·DB·PVC·runtime Secret은 삭제하지 않는다.

## AWX-04 SCM 운영 원본과 전용 EE

`AWX-04 platform 운영 원본`은 GitHub SSOT의 private Gitea pull-mirror만 `main`으로
동기화한다. project는 `scm_clean=true`, `scm_delete_on_update=true`,
`scm_update_on_launch=false`, `allow_override=false`이며 `projects_persistence=false`를
유지해 project PVC를 만들지 않는다. task Pod의 strict `known_hosts`는 bootstrap Hook이
인증된 Gitea host key를 Vault `kv/awx/scm-hostkeys`에서 읽어 Secret으로만 만든다.

Gitea read-only deploy key는 AWX credential에 저장하지 않는다. Source Control credential의
`ssh_key_data`는 built-in `HashiCorp Vault Secret Lookup` input source가 `kv/awx/scm`에서
읽고, provision Hook은 별도 AppRole bootstrap(`kv/awx/scm-lookup`)만 읽는다. bootstrap,
provisioner, runtime policy는 서로 이 키·Harbor pull credential·AppRole 값을 읽을 수 없다.

전용 `AWX-04 platform EE`는 Harbor digest
`sha256:0a35dcb1933fd6439730dd2a57e325be1bd175852c29dd0e2894728b16137bb9`만 사용한다.
Jenkins replay #17은 source `112fb2a25afc2bc774fe3040bf091c1c421a1398`에서
`community.postgresql 3.5.0`, 실제 role과 36개 playbook syntax를 확인한 뒤 Trivy,
CycloneDX SBOM, Cosign sign/verify를 통과했다. EE는 rootless builder의 `RUN` 없이 최신
Alpine Python runtime·고정 Ansible package·고정 OpenSSH runtime을 COPY하며, installer는
runtime image에 넣지 않는다.
Alpine base에 이름 없는 UID 1000이 OpenSSH에서 실패하지 않도록 OpenSSH bundle은 root와
`awx`(UID 1000) passwd/group entry만 함께 제공한다.

일상 `AWX Operators`에는 이 project와 `AWX-04 운영 원본 정보` check template의 read role만
부여한다. template에는 execute·credential use 권한이 없고 branch override도 받지 않으며,
운영 대상 job은 0개다. browser 검증은 `imcherry5778`의 project revision/template read 200과
project·EE·credential 수정 및 branch override 403을 같은 OIDC session으로 확인한다.

Rollback은 먼저 AWX child를 적용 전 main SHA로 sync하여 AWX-04 EE, SCM project와 Hook을
되돌리고 task/web Ready를 확인한다. 이어 `platform-root`와 child targetRevision을 literal
`main`으로 복원한다. GitHub/Gitea deploy key와 Vault path는 이 task의 rollback 범위에서만
삭제하며 기존 AWX-01 runtime Secret·DB·PVC·NetworkPolicy는 삭제하지 않는다.

### AWX-04 SCM AppRole 입력 보정

`awx-04-scm-lookup`의 Secret ID는 TTL을 가지므로, Vault login HTTP 400/403으로 project update가
중단되면 `refresh-scm-lookup.sh --apply`로 `kv/awx/scm-lookup`의 bootstrap 입력만 새로 만든다.
이는 deploy key·Gitea host key·Source Control credential·EE·role을 교체하지 않는다. 이어 AWX
main Sync hook의 SCM update 성공과 root/AWX `Synced/Healthy`만 확인한다. `--check`는 KV를
읽을 때만 bootstrap root token을 쓰고, AppRole login에는 그 token을 명시적으로 제거한다.
이미 인증된 root token을 AppRole login에 동봉하면 새 Secret ID도 403으로 오판한다.

실패 operation을 재개할 때 Application CRD의 `status` subresource를 patch하지 않는다.
이 CRD에는 해당 subresource가 없으므로 `NotFound`가 된다. `verify-fix-live.sh recover-main`은
최신 main SHA의 최상위 `operation.sync`를 한 번 요청해 선언된 automated Sync hook을 다시 실행한다.
`verify-main`은 이전 실패 상태가 아니라 이 latest SHA operation의 `Succeeded`와 그 뒤 SCM
project update 성공을 함께 기다린다.

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

### AWX-04 실행 Pod Harbor pull 보정

Harbor private EE에는 서로 다른 두 인증 형식이 필요하다. `awx-ee-pull-credentials`는
AWX Operator가 등록된 EE에 연결하는 Opaque Secret이며 `url`, `username`, `password`,
`ssl_verify`만 가진다. `awx-ee-pull`은 kubelet과 automation-job Pod가 실제 이미지를
가져오는 `kubernetes.io/dockerconfigjson` Secret이다. 둘은 bootstrap Hook이 같은 Vault
Harbor robot 입력에서 만들며, 원문은 Git이나 실행 출력에 남기지 않는다.

CR의 `image_pull_secrets`는 app/database Pod에 이 Docker config Secret을 연결하고,
`DEFAULT_EXECUTION_QUEUE_POD_SPEC_OVERRIDE`는 default Instance Group이 만드는 동적
automation-job Pod에 같은 `imagePullSecrets`를 연결한다. 이 보정은 Secret 형식과 실행
Pod 선언만 판정한다. private EE를 실제로 pull해 `k3s-01`에서 무변경 SSH를 실행하는 증거는
`AWX-05`가 단 한 번 소유한다.

## AWX-05 same-node SSH canary

AWX-05는 실제 운영 변경 전에 `k3s-01.imcherry5778.xyz` 한 대에서만
Machine credential 실행 경계를 확인한다. 새 SCM branch나 임시 Gitea `main`을 만들지 않고,
이미 root immutable SHA로 배포되는 `awx-manual-project` ConfigMap의
`awx05-ssh-canary.yml`만 사용한다. 따라서 AWX-04가 소유한 private Gitea mirror의
`main` 고정·deploy key 경계를 넓히지 않는다.

Machine private key는 `kv/awx/ssh-canary`에만 있고, `AWX-05 Vault Machine lookup`의
짧은 AppRole이 built-in Vault external input source로 `ssh_key_data` 한 필드만
resolve한다. Provision Hook·runtime/bootstrap policy는 private key를 읽지 못한다.
lookup AppRole Secret ID는 1시간 TTL이므로 Vault login HTTP 400/403이면 승인 후
`prepare-live.sh --refresh-lookup`으로 `kv/awx/ssh-canary-lookup`만 재발급한다. account,
private key, host key, policy와 role은 교체하지 않는다.
`awx-ssh-canary-known-hosts` Secret은 인증된 public host key 하나를 execution Pod의
`/etc/awx-ssh-canary/known_hosts`에 read-only mount한다.
플랫폼 EE는 UID 1000으로 실행되므로 default execution Pod는 PVC 대신 32 MiB `emptyDir`를
`/runner`에 mount해 Ansible Runner의 private data를 쓰게 한다.

`AWX-05 k3s-01 SSH canary` Job Template은 check-only, one-host limit, forks 1,
simultaneous 및 inventory/credential/branch/extra-vars override 금지, `become_enabled=false`다.
AWX 24.6.1의 built-in Machine credential에는 `ssh_common_args` 필드가 없으므로 strict
host-key 옵션은 이 전용 host 변수에서만 고정한다.
CR reconciliation 직후에는 web API보다 task dispatcher가 늦게 준비되거나 교체될 수 있으므로,
provision Hook은 오류 없는 enabled·capacity control/hybrid instance 집합이 20초 동안 안정된 뒤
inventory를 만든다.
`AWX Operators`에는 이 전용 inventory·credential의 use 및 template execute만 부여하며,
기존 운영 inventory와 다른 credential에는 권한을 추가하지 않는다. 실행 Pod egress는
`10.10.20.10/32:22` 한 경로만 추가한다. playbook 안의 두 read-only TCP 음성 판정은
다른 운영 host의 22와 k3s-01의 2222가 이 policy로 막혔음을 같은 job에서 확인한다.

Rollback은 `gitops/tools/awx-05/prepare-live.sh --rollback`으로 source 제한 account/key,
Vault KV/AppRole/policy를 제거하고, AWX child를 직전 main SHA로 sync한 다음
`platform-root`를 literal `main`으로 복원한다. AWX DB·기존 SCM deploy key·EE·PVC와
OPNsense는 이 범위에서 변경하거나 삭제하지 않는다.

## AWX-06 cross-VLAN 승인 marker

AWX-06은 `netbird-01.imcherry5778.xyz` 하나에서만 cross-VLAN SSH 경계를 실제로
확인한다. OPNsense에는 `opt2`의 `10.10.20.10 → 10.10.40.10 TCP 22` pass rule 하나를
NET-04 non-public block 바로 앞에 추가하고, execution Pod에는 같은 대상과 port만 허용하는
별도 NetworkPolicy를 둔다. 이외 VM·port·방화벽 rule은 확장하지 않는다.

전용 `awx-marker` account는 sudo/become 권한이 없고, `/var/lib/awx-marker`의 marker
파일 하나만 생성·삭제한다. private key는 `kv/awx/ssh-marker`의 external lookup role만 읽고,
인증된 netbird host key는 `awx-ssh-marker-known-hosts` Secret을 통해 execution Pod의
`/etc/awx-ssh-marker/known_hosts`에 read-only mount한다.

`AWX-06 netbird marker 승인` workflow는 precheck의 예상 `changed=1` 뒤 사람 승인을
기다린다. 승인 뒤 apply `changed=1`, idempotency check `changed=0`, cleanup으로 marker
부재를 확인한다. Operators는 precheck 및 workflow를 시작할 수 있지만 apply/cleanup template,
credential과 권한을 직접 수정할 수 없다. Approvers는 이 workflow의 approve/reject 역할만 가진다.

실패하면 `gitops/tools/awx-06/apply-firewall.sh rollback <STATE_DIR>`로 그 rule 하나를 먼저
삭제하고, `gitops/tools/awx-06/prepare-live.sh --rollback`으로 전용 account와 AWX/Vault
객체만 제거한다. root/AWX Application은 항상 literal `main`으로 복원한다.
