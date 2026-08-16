# DEMO-AWS-HR-01 실행기

세션 4의 AWS HR System 공급망 장면은 기존 EKS `ImageValidatingPolicy`를 바꾸지 않는다.
현재 `frontend` Deployment의 PodTemplate을 읽어 양성·음성 Pod를 만들고, 두 요청 모두
`kubectl create --dry-run=server`로만 admission에 보낸다. 따라서 image pull, Pod·ReplicaSet
생성, Deployment patch, build, ECR replication, GitOps digest 갱신은 일어나지 않는다.

촬영용 전체 판정은 한 명령이다.

```bash
gitops/tools/demo-aws-hr-01/demo.sh prove
```

필요하면 장면을 나누어 같은 순서로 실행한다.

```bash
gitops/tools/demo-aws-hr-01/demo.sh attack
gitops/tools/demo-aws-hr-01/demo.sh control
gitops/tools/demo-aws-hr-01/demo.sh evidence
gitops/tools/demo-aws-hr-01/demo.sh reset
```

- `attack`은 `frontend`와 같은 Pod shape에서 inert tag-only ECR fixture를 server-side
  dry-run해 `DENIED`를 확인한다. fixture는 실제로 pull하거나 실행하지 않는다.
- `control`은 같은 Pod shape에서 현재 `frontend`의 signed exact digest를 dry-run해
  `ALLOWED`를 확인한다.
- `evidence`는 양성/음성 요청 전후의 Deployment·ReplicaSet·Pod snapshot이 동일한지,
  세 서비스의 Ready·digest·UID가 변하지 않았는지, 합성 employee의 자기 history
  read-only HTTP 200과 Argo `hr-system=Synced/Healthy`를 확인한다.
- `reset`은 원격 Kubernetes delete를 하지 않는다. snapshot을 한 번 더 대조하고 로컬
  `/tmp/demo-aws-hr-01-state`만 없앤다. state가 없을 때도 성공하는 no-op이다.

합성 identity의 password/TOTP는 `/home/imcherry/secrets/ktcloud4-bean/hr-system-e2e`의
mode `0600` 파일만 읽는다. cookie, token, OTP, Secret, HR 응답 본문은 출력하지 않는다.
방화벽·public DNS·실제 Deployment·ECR artifact·Git 선언도 변경하지 않는다.

EKS API는 기존 private 경로의 일시 SOCKS tunnel로만 연결한다. 기본 local port `1099`가
사용 중이면 기존 tunnel을 공유하지 않고 중단한다. `DEMO_AWS_HR_SOCKS_PORT`는 빈 local
port로만 바꿀 수 있다.

## 실패와 fallback

음성 요청이 `DENIED`가 아니거나 양성 요청이 `ALLOWED`가 아니면 촬영을 중단하고 원시
응답을 출력하지 않은 채 실행기의 실패 단계만 기록한다. 이 실행기는 모든 workload mutation을
거부하므로 reset은 원격 no-op이고, 기존 `DEMO-ONPREM-01` 세션 4 공급망 장면만 fallback으로
사용한다. fallback은 이 HR System/EKS 결과를 대신 증명하지 않는다.
