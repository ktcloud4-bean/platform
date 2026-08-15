# SUPPLY-05-FIX-04 증거

## 판정

`DONE` — exact 예외의 양성 재생성과 인접 부정 케이스를 immutable SHA에서 확인했다.

## 확인된 실패 지점

- 기존 정책은 Wazuh system 예외의 모든 init container를 `docker.io/wazuh/*` 또는
  `docker.io/library/python:*`로 제한했다.
- 실제 `wazuh-manager-master`는 `hashicorp/vault:2.0.3` exact digest init container를
  사용하므로 재기동 때 `k3s-image-supply-chain-policy`의 upstream registry 거부가 발생했다.
- 임시 복구에서는 exact Pod·ServiceAccount·두 digest의 일회성 PolicyException만 사용했고,
  manager `1/1 Ready` 뒤 즉시 제거했다. ImageValidatingPolicy 본문은 바꾸지 않았다.
- 첫 부정 fixture는 StatefulSet controller가 Pod 생성 때 주입하는 PVC volume이 없어 API 구조
  검증에서 먼저 거부됐다. 응답의 `volumeMounts[].name: Not found`를 확인한 뒤 같은 이름의
  비영속 `emptyDir`를 fixture에만 보충해 공급망 정책 거부까지 도달하도록 고쳤다.

## 완료 증거 범위

- 두 Enforce/rollback 정책에 같은 exact manager 예외
- 같은 이미지·ServiceAccount지만 다른 Pod 이름은 server dry-run 거부
- immutable SHA에서 manager 실제 재기동, Pod UID 변경과 `1/1 Ready`
- Enforce/Fail 불변, 임시 예외·test Pod 0건, Argo literal main 복구

## 판정 출력

```text
SUPPLY05FIX04_STATIC=PASS renders=2 exact_manager_exception=2 backlog=valid
SUPPLY05FIX04_POLICY=PASS enforcement=Deny failurePolicy=Fail scope=exact-pod-sa-digests
SUPPLY05FIX04_NEGATIVE=PASS same_images=true different_name=denied resource_created=0
SUPPLY05FIX04_RECREATE=PASS pod=wazuh-manager-master-0 uid_changed=true ready=1/1
SUPPLY05FIX04_LIVE=PASS manager_recreated=true negative_denied=true transient_resources=0
SUPPLY05FIX04_ARGO_IMMUTABLE=PASS
SUPPLY05FIX04_ARGO_RESTORE=PASS
```

immutable 검증기는 작업 commit과 시작 시점 `origin/main`의 full SHA를 입력으로 받고,
실패 여부와 무관하게 `policy-baseline`과 `platform-root`를 literal `main`으로 복구한다.
