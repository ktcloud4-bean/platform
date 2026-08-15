# Keycloak 일회성 bootstrap 경계

이 디렉터리는 상시 `keycloak` Application에 포함되지 않는 수동 bootstrap 경계다.
Keycloak runtime Application은 Deployment·Service·Ingress만 reconcile하며, 완료된 Job을
자동으로 다시 만들지 않는다.

## 실행 전제

1. `keycloak` Application이 `Synced/Healthy`이고 Keycloak Deployment가 Ready인지 확인한다.
2. Vault Agent ConfigMap, trust bundle, bootstrap script가 runtime Application에 존재하는지 확인한다.
3. 대상 realm·복구 계정·MFA 정책·복구 client의 현재 상태를 read-only로 확인한다.
4. 실행 직전 별도 승인과 capacity를 확인하고, Job 이름과 image digest를 변경 이력에 기록한다.

## 실행과 정리

```sh
kubectl apply -k gitops/apps/keycloak-bootstrap
kubectl -n keycloak wait --for=condition=complete job/keycloak-bootstrap-v3 --timeout=15m
kubectl -n keycloak logs job/keycloak-bootstrap-v3 --all-containers=true
```

`bootstrap-job.yaml`은 check-first/no-op 스크립트와 curated digest를 사용한다. 성공한 Job은
`ttlSecondsAfterFinished`로 자동 정리되며, 증거를 저장한 뒤 남은 Pod/Job을 수동 정리할 수 있다.
다음 실행이 필요하면 이전 Job을 수정하지 말고 새 versioned Job 이름과 새 digest를 선언한다.

이 경계에는 Argo CD `Application`이 없다. 따라서 `platform-root` self-heal이나 일반 Keycloak
sync가 bootstrap을 재실행하지 않는다. 로그·상태 증거에는 secret, token, 원문 realm export를
넣지 않는다.
