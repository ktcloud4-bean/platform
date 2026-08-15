# SUPPLY-04-FIX-02: Keycloak bootstrap 수동 경계 분리 증거

## 범위

- 상시 `keycloak` Application에서 완료 bootstrap Job을 제거했다.
- check-first/no-op와 curated digest를 유지하는 Job은 [`gitops/apps/keycloak-bootstrap/`](../../../gitops/apps/keycloak-bootstrap/) 수동 경계로 옮겼다. 이 경계에는 Argo `Application`이 없다.
- 기존 라이브 `keycloak-bootstrap-v2`는 복원하거나 재실행하지 않았다. `v3`는 immutable 검증 중 정리됐고, `keycloak` Deployment와 DB·사용자·group membership·운영 client는 변경하지 않았다.

## 선언 검증

다음 범위만 1회 확인했다.

```text
bash -n gitops/tools/supply-04-fix-02/verify-live.sh        PASS
git diff --check                                            PASS
kubectl kustomize gitops/apps/keycloak                     PASS
kubectl kustomize gitops/apps/keycloak-bootstrap            PASS
```

상시 Application의 Kustomize에는 Job이 없고, 수동 경계의 `keycloak-bootstrap-v3`만
`ttlSecondsAfterFinished`, check-first/no-op 스크립트와 Harbor curated digest를 선언한다.
문서와 검증 출력에는 Secret·token·realm 원문을 넣지 않았다.

## immutable Argo 라이브 검증

검증 스크립트: [`gitops/tools/supply-04-fix-02/verify-live.sh`](../../../gitops/tools/supply-04-fix-02/verify-live.sh)

```text
SUPPLY-04-FIX-02 Argo=PASS bootstrap=manual-boundary runtime=healthy jobs=absent
```

검증 중 `platform-root`는 `b65065d53d4261133bfc5f0887b7862bbb80d069`, child
`keycloak`는 `aaeddec9ff38a61d249dfeb18570134a5a5a30f5`를 각각 새 history entry로
수렴했다. `keycloak` Deployment는 `readyReplicas/availableReplicas=1/1`이었고
`keycloak-bootstrap-v2`, `keycloak-bootstrap-v3` Job은 모두 없었다. 검증 종료 시
`platform-root`와 `keycloak`의 `targetRevision`을 literal `main`으로 복원했으며,
현재 라이브 상태는 두 Application 모두 `Synced/Healthy`, main revision
`af528ae018f25b36fc7ef495ce8659bd0dbf9353`이다.

## 판정

상시 reconcile 경계와 일회성 bootstrap 경계를 분리해 완료 Job의 self-heal 재실행
경로를 제거했다. 다음 bootstrap이 필요할 때는 별도 승인 후 수동 경계에서 새
versioned Job을 실행하고, 성공 로그를 보존한 뒤 TTL 정리를 따른다.
