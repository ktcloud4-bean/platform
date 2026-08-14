# AWX-04-FIX-03 완료 증거

`AWX-04 platform 운영 원본`의 project update `78`은 만료된 SCM lookup
Secret ID로 Vault AppRole login 403이 발생해 중단됐다. `kv/awx/scm-lookup`의
새 Secret ID 발급·저장은 성공했고, canonical Role ID와 함께 Vault에 등록된 상태를
비밀 원문 없이 확인했다.

이후 recovery verifier의 재확인도 403이었지만, 이는 AppRole 문제가 아니다. helper가
bootstrap KV를 읽기 위해 가진 root token을 AppRole login에도 동봉한 것이 원인이었다.
같은 Role ID·Secret ID에서 root token을 제거하면 AppRole login과 `kv/awx/scm`의 deploy-key
read가 성공했다.

보정은 `refresh-scm-lookup.sh --check`의 AppRole login에서만 `VAULT_TOKEN`을 제거하는
것이다. AppRole role/policy, deploy key, Gitea host key, Source Control credential, EE,
RBAC, PVC, OPNsense는 변경하지 않는다. 완료는 fixed helper check와 다음 AWX SCM project
update 성공, 최신 `main` root/AWX `Synced/Healthy`로 판정한다.

기존 recovery helper의 두 번째 결함도 함께 보정한다. live Application CRD에는 `status`
subresource가 없어 그 endpoint patch는 `NotFound`가 된다. helper는 status를 고치지 않고,
latest main SHA를 가리키는 최상위 `operation.sync`를 한 번 요청해 Sync hook을 재실행한다.
완료 판정은 이전 failed operation의 `Synced/Healthy`를 재사용하지 않고, 이 SHA operation의
`Succeeded`와 그 뒤 SCM project update 성공을 함께 요구한다.

## 실행 결과

- bearer 없는 AppRole login과 deploy-key read가 성공했다. 비밀 원문은 출력하지 않았다.
- latest main `ec1077e7b9e189f28aa07fe4028db169ff0654c3`의 explicit Sync operation 뒤
  SCM project update `79`가 성공했다.
- root/AWX는 literal `main`, `Synced/Healthy`로 복원됐다.
