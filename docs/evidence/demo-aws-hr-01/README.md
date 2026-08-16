# DEMO-AWS-HR-01 완료 증거

## 범위

세션 4의 HR System/EKS 촬영 인터페이스는 기존 `SUPPLY-01-FIX-02`의 Kyverno 공급망
통제를 재구현하거나 변경하지 않는다. 현재 HR `frontend` PodTemplate으로 양성·음성
server-side dry-run을 만들고, 실행 전후의 서비스 상태를 비교한다.

## 판정 기준

| 항목 | 기준 | 실행기 판정 |
|---|---|---|
| 음성 admission | inert tag-only ECR fixture를 현재 frontend와 같은 Pod shape·`hr-system` namespace에서 server-side dry-run | `DENIED` |
| 양성 admission | 현재 signed frontend exact digest를 같은 Pod shape·namespace에서 server-side dry-run | `ALLOWED` |
| 무중단 | 음성 요청 전후 새 ReplicaSet·Pod 0, 기존 frontend·employee-service·hr-service Ready·digest·UID 불변 | snapshot 동일 |
| 사용자 경로 | 합성 employee의 인증된 HR 포털 자기 history GET | read-only HTTP 200 |
| GitOps 상태 | k3s Argo `hr-system` | `main` / `Synced` / `Healthy` |
| reset | remote Kubernetes delete 0, 로컬 state만 제거 | no-op |

## 실측 결과 (2026-08-16)

`gitops/tools/demo-aws-hr-01/demo.sh prove`를 한 번 실행해 아래 결과를 얻었다.

| 단계 | 실측 결과 | 판정 |
|---|---|---|
| attack | same frontend Pod shape의 inert tag-only fixture가 server-side dry-run에서 거부되고, 직후 ReplicaSet·Pod snapshot 변동 0 | `DENIED` |
| control | same frontend Pod shape의 현재 signed exact digest가 server-side dry-run에서 허용되고, 직후 ReplicaSet·Pod snapshot 변동 0 | `ALLOWED` |
| evidence | frontend·employee-service·hr-service `Ready`, digest·UID 불변; synthetic employee history read-only 200; Argo `hr-system=Synced/Healthy` | `PASS` |
| reset | remote Kubernetes delete 0, local state cleared | `PASS` |

사전 read-only 점검에서도 세 Deployment가 모두 `1/1`·digest pinned이고 EKS
`ImageValidatingPolicy`가 `Deny/Fail`임을 확인했다. 이미지 build·replication·ECR publish,
GitOps digest 변경, 실제 Deployment patch, 악성코드·실데이터·Secret 출력은 모두 0건이다.

## 실행 경계

`gitops/tools/demo-aws-hr-01/demo.sh prove`는 `attack → control → evidence → reset`을 한
번에 수행한다. 두 admission 요청은 `create --dry-run=server`뿐이고 apply, patch, delete,
rollout, build, replication, ECR publish, GitOps digest update를 호출하지 않는다. fixture는
tag-only라 정책의 digest 고정 검사에서 거부되며 실제 image pull 또는 Pod 실행이 없다.

합성 identity는 기존 `QUALITY-06` employee만 재사용한다. credential은 mode `0600` 파일로만
읽고 cookie·token·OTP·Secret·HR 응답 body·실데이터를 출력하지 않는다.

## 실패 처리와 fallback

`DENIED`/`ALLOWED`/snapshot 동일 중 하나라도 만족하지 않으면 해당 실패 단계를 기록하고
촬영하지 않는다. 실행기가 workload mutation을 만들지 않으므로 reset은 원격 no-op이다.
대체 화면은 완료된 `DEMO-ONPREM-01` 세션 4로 한정하며, 그 결과를 HR System/EKS 공급망
증거로 표현하지 않는다.
