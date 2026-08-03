# Vault GitOps 적용 경계

일상 선언은 `platform-root` → child Application `vault`가 literal `main`에서 소유한다.
`KMS-01` seal migration에서만 `ARGO-ROOT`와 `VAULT-INIT`을 함께 단독으로 잡고 최신
`origin/main`에 rebase한 immutable commit SHA를 임시로 읽는다.

## VAULT-03: Vault UI 노출

Vault UI는 `ingress.yaml`(표준 `networking.k8s.io/v1` Ingress)로 노출하며 **Pomerium을
경유하지 않는다**. [architecture.md](../../../docs/architecture.md)의 요구는 "Vault 복구는
Pomerium이나 Dashy를 유일한 경로로 삼지 않는다"이지 노출 금지가 아니다. Pomerium을 고치기
위해 봐야 하는 대상이 Vault인데 그 Vault를 Pomerium 뒤에 두면 복구 순환이 생기므로, 권한
판정은 Vault 자체 OIDC auth method(`auth/oidc`)와 policy가 전담한다.

- **backend TLS 신뢰**: Vault listener는 자체서명 TLS다(VAULT-01). `serverstransport.yaml`이
  선언하는 `ServersTransport`(`vault-backend-tls`)와 그 전용 `Secret`(`vault-ingress-ca`,
  public leaf 인증서 하나만 담음, private key 없음)이 Traefik→Vault backend 홉의 TLS 신뢰를
  구성한다. `serverName`은 인증서 SAN에 있는 `vault.vault.svc.cluster.local`을 쓴다. 기존
  Pomerium Route 8건은 전부 평문 HTTP upstream이라 이 경로에만 필요하다. 이 Secret은 VAULT-01이
  이미 `keycloak-trust-bundles` ConfigMap으로 git에 공개한 것과 같은 바이트이므로 새로 비밀이
  느는 것은 아니다.
- **OIDC auth method·policy**: `infra/vault/scripts/configure-vault-03-oidc.sh`가
  `auth/oidc`를 켜고 `policies/vault-ui-operator.hcl`(`kv/data/*`, `kv/metadata/*` read/list만)을
  쓰며, `auth/oidc/role/ui-viewer`와 identity group(external, `vault-ui-platform-privileged`)의
  group-alias를 Keycloak `groups` claim의 `/platform-privileged`에 연결한다. `/platform-users`만
  가진 로그인은 Vault 내장 `default` policy만 받아 `kv/data/*` 읽기도 403이다. `sys/mounts`처럼
  policy가 열지 않은 경로는 `/platform-privileged`로 로그인해도 403이다.
- **Keycloak client**: `gitops/tools/vault-03/keycloak-client.json` + 동봉
  `provision-keycloak-client.sh`(check-first)가 confidential Authorization Code client
  `vault` 하나를 만든다. redirect URI는 Vault UI의 실제 callback 경로
  `https://vault.imcherry5778.xyz/ui/vault/auth/oidc/oidc/callback` 하나뿐이다.
- **break-glass 보존**: root token과 `kubectl port-forward svc/vault 8200`은 그대로 유지한다.
  OIDC는 추가된 경로일 뿐 기존 접근을 대체하지 않는다.
- **DNS**: `gitops/tools/vault-03/opnsense-alias.py`가 `vault` 내부 alias 1건만 관리한다.
  공개 A/AAAA와 내부 AAAA는 만들지 않는다. 정확한 hostname과 노출 정의의 단일 원본은
  [`docs/ip-plan.md`](../../../docs/ip-plan.md)다.
- Vault 내부 구성(oidc mount·policy·identity group)은 Argo가 동기화하지 않는다. 다른 mount와
  같은 이유로 [`infra/vault/README.md`](../../../infra/vault/README.md)가 재현 스크립트를 소유한다.

## KMS-01 선행 순서

1. AWS `tofu-kms` create plan을 승인·적용하고 외부 mode `0600` env를 회수한다.
2. `gitops/tools/kms-01/reconcile-awskms-secret.sh --apply`로 `vault-awskms` Secret을 먼저 만든다.
   Secret 적용은 Pod를 재생성하지 않는다.
3. 사전 Raft snapshot을 만든 뒤 최신 main에 rebase한 설정 commit을 push한다. 다음 pointer
   commit에서 `vault` child만 설정 SHA로 고정하고 `platform-root`는 pointer SHA를 읽는다.
   설정 SHA의 ConfigMap과 StatefulSet env 변경이 Vault Pod를 한 번 재생성한다.
4. Pod가 seal migration 대기 상태일 때 기존 Shamir share 3개를 모두 `migrate=true`로 제출한다.
5. 장애 시험·rollback drill·recovery rekey가 끝나면 정상 auto-unseal 선언만 남긴 최종 SHA로
   돌아온다. child manifest의 `targetRevision`은 항상 literal `main`이다.

Vault Agent init을 가진 다른 workload Pod를 삭제·rollout하거나 cert-manager Issuer를 검증하는
작업은 이 창과 겹치지 않는다. KMS public API endpoint를 사용하므로 VPN Application과 OPNsense는
이 순서에 참여하지 않는다.

## credential과 rollback

`vault-awskms` Secret은 GitOps가 원문을 소유하지 않는 bootstrap 자산이다. 원본은 저장소 밖
`$KTC_SECRET_ROOT/kms-01/env`이고, Secret에는 `AWS_ACCESS_KEY_ID`와
`AWS_SECRET_ACCESS_KEY`만 있어야 한다. 값 확인은 reconcile script의 exact match로만 하며
Secret YAML이나 base64를 출력하지 않는다.

auto-unseal → Shamir drill은 KMS seal block에 `disabled = "true"`를 넣고 child를 literal `main`으로
돌린 설정 commit, 그 설정 SHA를 child에 넣은 pointer commit 순으로 적용한다. 성공 뒤 같은 두
commit 구조로 정상 KMS block에 다시 migration한다. 최종 선언에는 `disabled`가 없어야 하고 child도
literal `main`이어야 한다. 실패하면 시작 main SHA의 Shamir 선언 또는 이미 검증한 정상 KMS SHA로
root/child를 돌리고, 그 seal 상태에 맞는 share를 제출한다. PVC·Raft data와 KMS key는 삭제하지 않는다.
