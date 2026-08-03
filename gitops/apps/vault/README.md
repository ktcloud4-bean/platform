# Vault GitOps 적용 경계

일상 선언은 `platform-root` → child Application `vault`가 literal `main`에서 소유한다.
`KMS-01` seal migration에서만 `ARGO-ROOT`와 `VAULT-INIT`을 함께 단독으로 잡고 최신
`origin/main`에 rebase한 immutable commit SHA를 임시로 읽는다.

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
