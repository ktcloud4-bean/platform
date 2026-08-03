# Vault AWS KMS auto-unseal · OpenTofu

`KMS-01`이 소유하는 네 번째 AWS OpenTofu root다. Vault의 root key를 감싸는 대칭 KMS key와
그 key만 쓰는 service identity를 선언한다.

## state 경계

이 root는 다음 5개 자원만 소유한다.

- 대칭 single-Region KMS key 1개와 alias 1개
- `/service/` 경로의 Vault 전용 IAM user 1개
- 그 user의 exact-key inline policy 1개
- 그 user의 access key 1개

`infra/aws/tofu`의 삭제 방지 오프사이트 bucket·전송 identity, `tofu-network`의 비용 gate가
있는 VPN/VPC, `tofu-identity`의 사람용 SAML role은 수명주기와 rollback이 다르므로 어느 state에도
KMS 자원을 섞지 않는다. 특히 오프사이트 bucket은 계속 SSE-S3를 사용한다. Vault 부팅용 KMS key를
백업 암호화에도 재사용하면 KMS 장애가 Vault 부팅과 백업 복호화를 동시에 막기 때문이다.

state에는 IAM secret access key가 평문으로 남는다. backend path, 실제 tfvars, plan과 credential
출력은 모두 저장소 밖 `${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/kms-01/` mode `0700`
directory 안의 mode `0600` 파일만 사용한다.

## 최소권한

Vault Community auto-unseal이 요구하는 action은 공식 문서의 세 개뿐이다.

```json
{
  "Effect": "Allow",
  "Action": ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt"],
  "Resource": "<이 root가 만든 KMS key ARN 하나>"
}
```

`GenerateDataKey`, grant, alias 조회, key 변경·삭제, IAM action과 다른 KMS key는 허용하지 않는다.
key policy는 계정 root의 관리·IAM 위임 경로만 보존하고 Vault user 권한은 위 inline policy 하나가
결정한다. `enable_vault_kms_access=false`는 장애 시험 중 그 policy만 회수하며 user, access key,
KMS key는 유지한다. `true` 재적용이 rollback이다.

## 비용·감사 기준

- AWS KMS customer managed key는 1개당 월 USD 1(시간 비례)이다.
- 대칭 key의 `Encrypt`·`Decrypt` 요청은 월 계정 합산 20,000건 free tier 뒤 10,000건당
  USD 0.03이다. 일 1회 재기동을 가정한 `Decrypt` 31건은 free tier가 모두 소진돼도
  약 USD 0.000093/월이다.
- 자동 KMS key rotation은 첫 두 번의 rotation 뒤 각각 월 USD 1이 더해지므로 이 작업에서는
  켜지 않는다. key 교체는 별도 migration·rollback 작업으로 한다.
- AWS KMS API는 CloudTrail management event로 기록된다. 기본 Event history는 최근 90일을
  무료로 조회할 수 있다. 완료 판정은 실제 migration/restart의 `Encrypt`·`Decrypt`와 장애
  시험의 거부 event를 `EventSource=kms.amazonaws.com`에서 확인한다.

가격과 기록 범위는 2026-08-03 기준
[AWS KMS pricing](https://aws.amazon.com/kms/pricing/),
[AWS KMS CloudTrail logging](https://docs.aws.amazon.com/kms/latest/developerguide/logging-using-cloudtrail.html),
[CloudTrail Event history](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/view-cloudtrail-events.html)를
따른다. 실제 과금 대기는 완료 조건이 아니다.

## plan과 apply

```bash
export KTC_SECRET_ROOT=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
umask 077
install -d -m 700 "$KTC_SECRET_ROOT/kms-01"

# 기존 AWS root의 account guard와 같은 계정 ID만 저장소 밖에 입력한다.
install -m 600 /dev/null "$KTC_SECRET_ROOT/kms-01/kms.tfvars"
# aws_account_id = "<12자리 계정 ID>"

cd infra/aws/tofu-kms
mise exec opentofu@1.12.5 -- tofu init -reconfigure \
  -backend-config="path=$KTC_SECRET_ROOT/kms-01/terraform.tfstate"
mise exec opentofu@1.12.5 -- tofu validate
mise exec opentofu@1.12.5 -- tofu plan \
  -var-file="$KTC_SECRET_ROOT/kms-01/kms.tfvars" \
  -out="$KTC_SECRET_ROOT/kms-01/create.tfplan"
```

OpenTofu local backend가 기존 umask 아래 state를 `0644`로 만들 수 있으므로 `umask 077`은 선택이
아니다. init/apply 뒤 state와 backup state의 mode가 `0600`인지 다시 확인한다.

승인 뒤에만 `tofu apply "$KTC_SECRET_ROOT/kms-01/create.tfplan"`을 실행한다. 적용 결과를 화면에
출력하지 않고 외부 env로 회수한다.

```bash
mise exec opentofu@1.12.5 -- tofu output -json \
  >"$KTC_SECRET_ROOT/kms-01/tofu-outputs.json"
chmod 600 "$KTC_SECRET_ROOT/kms-01/tofu-outputs.json"
jq -r '"AWS_ACCESS_KEY_ID=" + .vault_access_key_id.value,
       "AWS_SECRET_ACCESS_KEY=" + .vault_secret_access_key.value' \
  "$KTC_SECRET_ROOT/kms-01/tofu-outputs.json" \
  >"$KTC_SECRET_ROOT/kms-01/env"
chmod 600 "$KTC_SECRET_ROOT/kms-01/env"
```

[`reconcile-awskms-secret.sh`](../../../gitops/tools/kms-01/reconcile-awskms-secret.sh)는 이 외부 env
두 key만 읽어 `vault/vault-awskms` Secret과 exact match를 확인한다. credential을 stdout,
명령 인자 또는 저장소 파일에 넣지 않는다.

## 장애 시험과 폐기

장애 시험은 `enable_vault_kms_access=false` plan이 inline policy 하나만 삭제함을 확인한 뒤
적용한다. IAM 전파 지연을 제거하려고 **Vault service credential**의 `DescribeKey`가
`AccessDenied`가 될 때까지 기다린 다음 Vault Pod를 한 번만 재생성한다. KMS `AccessDenied`와
NotReady를 확인하면 즉시 `true` plan으로 같은 policy를 복구하고, 같은 Pod가 share 입력 없이
auto-unseal되는지 확인한다. 실행 중 Vault를 API로 seal하는 방식은 재기동 전까지 KMS를 다시
호출하지 않아 장애 시험이 아니며, endpoint 차단을 중복해서 시험하지 않는다.

KMS key에는 `prevent_destroy`와 30일 deletion window가 있다. 폐기는 먼저 Vault를 Shamir로
migration하고 새 Shamir key로 재부팅을 확인한 별도 작업에서만 `prevent_destroy`를 해제한다.
일상 rollback은 key를 삭제하지 않고 IAM policy를 복구하거나 정상 auto-unseal 선언으로 되돌린다.
