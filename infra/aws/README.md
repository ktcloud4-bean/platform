# AWS OpenTofu Jenkins plan 경계

작업: `AWS-CI-FIX-01`

선행: `CI-01`, `SCAN-01`
잠금: `ARGO-ROOT`, `TOFU-STATE`

이 디렉터리의 기존 Jenkinsfile은 controller 밖의 Kubernetes agent에서 실행되지만,
Gitea의 recovery repository와 여러 AWS root, UI apply 입력을 한 job에 섞고 있었다.
이 작업은 그 job을 app network와 ECR의 **plan 전용** 검증기로 좁힌다. AWS account,
backend 값과 비밀 원문은 Git에 넣지 않는다.

## 실행 경계

| 항목 | 선언 | 이유 |
|---|---|---|
| Git source | GitHub `ktcloud4-bean/platform` 한 repository, port 443 SSH | recovery Gitea repository 부재와 분리하고, 방화벽 환경에서도 고정 host key를 쓴다 |
| 허용 root | `tofu-app-network`, `tofu-app-ecr` | app DB·EKS·KMS·identity·VPN·backend root는 이 CI 범위 밖이다 |
| Jenkins 동작 | `init`·`validate`·`plan`만 | Jenkinsfile·JCasC에 `apply`·manual input을 두지 않아 UI 승인으로 권한을 넓히지 않는다 |
| 실행 Pod | `aws-opentofu` 동적 Pod | controller executor 0, non-root, capability 전부 drop, SA token 없음, 종료 시 workspace 삭제 |
| AWS guard | account ID SHA-256 비교 | 실제 account ID를 Git과 Jenkins log에 남기지 않고 잘못된 credential을 중단한다 |

`awscli` sidecar가 STS로 account ID만 mode `0600` workspace 파일에 쓰고, OpenTofu
container의 `gitops/tools/aws-ci-fix-01/run-opentofu.sh`가 그 값을 해시 guard로 확인한다.
AWS provider 압축 해제와 backend.hcl·plan 파일은 OpenTofu container 전용의 pod-lifetime
scratch `emptyDir`에만 만들며, account 파일·backend 파일·plan 파일·provider cache는 build
종료 때 지운다.

## state 없는 최초 실행

`tofu-app-network`·`tofu-app-ecr`에 기존 state나 AWS 리소스가 없으면 state 객체 부재는
정상이다. Jenkins는 없는 key의 `HeadObject`가 `404`인 상태에서 plan을 만들 뿐, 빈
`terraform.tfstate`를 만들거나 업로드하지 않는다.

기존 `terraform.tfstate` key는 객체·version 이력이 없는 상태에서도 Jenkins principal에만
`403`을 반환했다. 같은 bucket의 임의 없는 key는 `404`이고 IAM inline policy·bucket
policy·permissions boundary·Organizations 제어 정책에는 해당 deny가 없었다. state가 없는
두 root만 `v1/terraform.tfstate` namespace로 새로 선언했다. 기존 key와 AWS 리소스는
읽거나 바꾸지 않는다.

첫 실제 생성은 Jenkins가 아니라 별도 administrator OpenTofu 실행에서 한다.

1. Jenkins plan의 생성 대상과 비용을 검토한다.
2. `TOFU-STATE` 잠금 아래 같은 `v1` backend로 administrator가 `plan`을 다시 만든다.
3. 명시 승인 뒤 administrator가 `apply`한다. 이 apply가 첫 state 객체를 자동 기록한다.
4. 이후 Jenkins plan은 그 state만 읽고 lock을 사용한다.

이미 존재하는 AWS 리소스를 빈 `v1` state에 apply하면 중복 생성 또는 충돌을 계획한다.
그 경우 이 절차를 쓰지 않고, 복구한 state 또는 `import`로 실제 소유권을 먼저 복원한다.

## legacy root state

오프사이트 root와 Site-to-Site VPN root는 각각 별도 S3 state key와 DynamoDB lock을 쓴다.
이 두 key는 Jenkins IAM policy·Pod allowlist의 범위 밖이며 administrator OpenTofu만 접근한다.
`AWS-STATE-RECOVERY-01`은 유실된 local state를 import로 복구하고 무변경 plan을 확인한 뒤
이전한 기록이다. 두 root의 state를 하나로 합치거나 Jenkins 권한에 추가하지 않는다.

## 동적 입력과 정리

GitHub read-only deploy key와 Vault runtime의
`github_platform_ssh_private_key` field는 다음 도구만 소유한다.

```bash
gitops/tools/aws-ci-fix-01/provision-github-source.sh --apply
gitops/tools/aws-ci-fix-01/provision-github-source.sh --check
```

도구는 같은 제목의 key가 정확히 하나이고 read-only이며 Vault private key와 public keypair가
일치할 때만 통과한다. 기존/부분 credential은 덮어쓰거나 자동 삭제하지 않는다.

Jenkins AWS IAM user에는 아래 policy만 별도로 붙인다.

```bash
gitops/tools/aws-ci-fix-01/provision-aws-state-policy.sh --apply
gitops/tools/aws-ci-fix-01/provision-aws-state-policy.sh --check
```

권한은 state bucket의 metadata list·location, 두 `v1` state object의 lifecycle,
그리고 lock table 한 개의 lease operation으로 고정된다. root resource 생성 권한은 이
policy에 없다. 중단/rollback에서는 세 도구의 `--destroy`가 자신이 정확히 생성한 field와
inline policy만 회수한다.

resource plan의 AWS API read 권한은 별도 policy가 소유하며, 실패한 Jenkins build의
`UnauthorizedOperation` 응답으로 확인한 action만 추가한다. 현재 network root에는 AZ data
source의 `ec2:DescribeAvailabilityZones`만 승인돼 있다.

```bash
gitops/tools/aws-ci-fix-01/provision-aws-plan-read-policy.sh --apply
gitops/tools/aws-ci-fix-01/provision-aws-plan-read-policy.sh --check
```

## 검증과 rollback

정적 증거는 한 경로만 쓴다.

```bash
gitops/tools/aws-ci-fix-01/verify-static.sh
```

이 검증은 JCasC 렌더·Pod 보안·root allowlist·account guard·partial backend·두 root의
backend 없는 init/validate와 Trivy positive/negative gate만 판정한다. AWS resource 생성,
state bootstrap apply, 다른 root, 공개 DNS·방화벽은 이 작업의 증거에 포함하지 않는다.

merge 전 live 검증은 `ARGO-ROOT` 잠금에서 immutable SHA로 Jenkins child를 전환하고 두
root build의 `SUCCESS`와 plan-only log summary를 확인한다. 실패 또는 검증 종료 시 root와
child를 literal `main`으로 돌린다. main에 통합되지 않은 시도가 중단되면 deploy key와 state
policy를 먼저 회수한 뒤 작업 branch/worktree를 정리한다.
