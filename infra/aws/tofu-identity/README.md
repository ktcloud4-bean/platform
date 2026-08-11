# AWS Keycloak SAML 임시 콘솔 권한 · OpenTofu

`AWS-ID-01`이 만든 세 번째 AWS OpenTofu root를 `AWS-ID-02`가 확장한다. Keycloak
`platform` realm의 SAML assertion으로만 AWS 콘솔 `AssumeRoleWithSAML` 임시 세션을
발급하며, AWS 계정은 하나로 유지한다.

## state 경계

이 root는 IAM SAML provider 하나와 사람용 읽기 IAM role 네 개만 소유한다.

- `infra/aws/tofu`는 오프사이트 backup bucket·전송 service user와 access key를 소유한다.
  bucket의 `prevent_destroy`와 복구 자산을 이 root의 `destroy` 사정권에 넣지 않는다.
- `infra/aws/tofu-network`는 VPC·Site-to-Site VPN만 소유한다. VPN 비용 gate와 IAM
  federation의 수명 주기가 다르므로 state를 공유하지 않는다.
- 계정의 기존 IAM user, service user, bucket, VPC, VPN, role, SAML provider는 여기서
  `resource`로 선언하거나 `import`하지 않는다.

이는 [ADR-0008](../../../docs/adr/0008-opentofu-provider-and-state-boundary.md)의
"state는 자신이 만든 자원만 소유" 원칙을 AWS 계층에도 적용한 것이다. SAML IdP metadata와
role ARN도 local state에 남으므로 state·plan·실제 tfvars는 저장소 밖 mode `0600`으로 보관한다.

## role과 최소 권한

| Keycloak 그룹 | AWS role | 허용 범위 | 명시적 제외 |
|---|---|---|---|
| `/aws-console-inventory-readers` | `platform-saml-observer` | VPN/VPC·EKS·RDS·ECR·ELB inventory 조회, 현재 임시 session 확인 | 모든 변경, IAM, S3·backup bucket |
| `/aws-console-observability-readers` | `platform-saml-observability-reader` | CloudWatch metric/alarm·CloudWatch Logs query 조회 | 모든 변경, IAM, S3·backup bucket |
| `/aws-console-security-readers` | `platform-saml-security-reader` | Access Analyzer·CloudTrail·IAM role/SAML provider 보안 구성 조회 | 모든 변경, IAM user/access key, `PassRole`, `AssumeRole`, S3·backup bucket |
| `/aws-console-identity-readers` | `platform-saml-identity-reader` | inventory 조회 + 이 root의 네 role과 SAML provider 읽기 | 모든 변경, IAM user/access key, `PassRole`, `AssumeRole`, S3·backup bucket |

네 role의 trust policy는 이 root가 만든 federated SAML provider ARN과
`SAML:aud=https://ap-northeast-2.signin.aws.amazon.com/saml`을 함께 요구한다. AWS의
`SAML:aud`는 assertion의 `Audience`가 아니라 `Recipient`에서 파생하므로, Keycloak의 서울
ACS와 trust policy를 같은 값으로 둔다. 다른 IdP assertion이나 다른 AWS 계정의 provider가
role을 assume할 수 없다. role의 최대 세션은 1시간이며 Keycloak은
SAML `SessionDuration=900`으로 AWS 콘솔 세션을 15분만 요청한다.

`AdministratorAccess`, IAM user, 사용자 access key, `sts:AssumeRole`, `iam:PassRole`은
선언하지 않는다. 기존 `seaweedfs-offsite-backup`은 backup service identity이므로 이 root의
대상이 아니며, 사람용 IAM user에 access key가 0개인지 별도로 검증한다.

## 적용 전 gate와 실행

적용자는 AWS 관리자 자격증명을 표준 profile 또는 환경변수로만 주입한다. role과 provider를
처음 만드는 bootstrap 관리자 자격증명은 사람이 보관하는 별도 경계이며, SAML role이 그
bootstrap 권한을 대체하지 않는다.

```sh
export AWS_ID01_SECRET_DIR=/home/<operator>/secrets/ktcloud4-bean/aws-id-01
install -d -m 700 "$AWS_ID01_SECRET_DIR"
curl --fail --silent --show-error \
  https://sso.imcherry5778.xyz/realms/platform/protocol/saml/descriptor \
  >"$AWS_ID01_SECRET_DIR/keycloak-platform-metadata.xml"
chmod 600 "$AWS_ID01_SECRET_DIR/keycloak-platform-metadata.xml"

cat >"$AWS_ID01_SECRET_DIR/identity.tfvars" <<'EOF'
aws_account_id      = "<12자리 계정 ID>"
saml_metadata_file  = "/home/<operator>/secrets/ktcloud4-bean/aws-id-01/keycloak-platform-metadata.xml"
EOF
chmod 600 "$AWS_ID01_SECRET_DIR/identity.tfvars"

cd infra/aws/tofu-identity
tofu fmt -check -recursive
tofu init -backend-config="path=$AWS_ID01_SECRET_DIR/terraform.tfstate"
tofu validate
tofu plan -var-file="$AWS_ID01_SECRET_DIR/identity.tfvars" -out="$AWS_ID01_SECRET_DIR/identity.tfplan"
```

승인 gate에서 다음을 사람이 함께 확인한다.

1. `AWS-ID-02` plan의 주소가 기존 observer/identity 정책 갱신과 아래 새 role/policy 네
   개뿐이며 `destroy=0`이다. provider와 VPN·backup root는 이행 plan의 대상이 아니다.
   ```text
   aws_iam_role.observability_reader
   aws_iam_role.security_reader
   aws_iam_role_policy.observability_reader_permissions
   aws_iam_role_policy.security_reader_permissions
   ```
2. `infra/aws/tofu`의 backup bucket·service user/access key와
   `infra/aws/tofu-network`의 VPN/VPC가 plan에 전혀 없다.
3. Keycloak metadata의 entity ID가 `https://sso.imcherry5778.xyz/realms/platform`이고
   metadata는 화면·Git·로그에 원문을 출력하지 않았다.
4. VPN Connection을 켜거나 끄지 않으며 VLAN, OPNsense, 공개 DNS/NAT를 바꾸지 않는다.

승인 뒤에만 다음을 실행한다.

```sh
tofu apply "$AWS_ID01_SECRET_DIR/identity.tfplan"
tofu plan -var-file="$AWS_ID01_SECRET_DIR/identity.tfvars"
```

두 sensitive output은 화면에 복사하지 않는다. 아래처럼 저장소 밖 mode `0600` env file로만
Keycloak reconcile script에 전달한다.

```sh
umask 077
tofu output -json >"$AWS_ID01_SECRET_DIR/tofu-outputs.json"
jq -r '.keycloak_saml_provider_arn.value' "$AWS_ID01_SECRET_DIR/tofu-outputs.json" \
  >"$AWS_ID01_SECRET_DIR/provider-arn"
jq -r '.keycloak_saml_role_arns.value.observer' "$AWS_ID01_SECRET_DIR/tofu-outputs.json" \
  >"$AWS_ID01_SECRET_DIR/observer-role-arn"
jq -r '.keycloak_saml_role_arns.value.identity_reader' "$AWS_ID01_SECRET_DIR/tofu-outputs.json" \
  >"$AWS_ID01_SECRET_DIR/identity-reader-role-arn"
jq -r '.keycloak_saml_role_arns.value.observability_reader' "$AWS_ID01_SECRET_DIR/tofu-outputs.json" \
  >"$AWS_ID01_SECRET_DIR/observability-reader-role-arn"
jq -r '.keycloak_saml_role_arns.value.security_reader' "$AWS_ID01_SECRET_DIR/tofu-outputs.json" \
  >"$AWS_ID01_SECRET_DIR/security-reader-role-arn"
export AWS_ID01_SAML_PROVIDER_ARN="$(<"$AWS_ID01_SECRET_DIR/provider-arn")"
export AWS_ID01_OBSERVER_ROLE_ARN="$(<"$AWS_ID01_SECRET_DIR/observer-role-arn")"
export AWS_ID01_IDENTITY_READER_ROLE_ARN="$(<"$AWS_ID01_SECRET_DIR/identity-reader-role-arn")"
export AWS_ID02_OBSERVABILITY_READER_ROLE_ARN="$(<"$AWS_ID01_SECRET_DIR/observability-reader-role-arn")"
export AWS_ID02_SECURITY_READER_ROLE_ARN="$(<"$AWS_ID01_SECRET_DIR/security-reader-role-arn")"
export KC01_SECRET_DIR=/home/<operator>/secrets/ktcloud4-bean/keycloak
scripts/reconcile-keycloak-saml-aws-id-02.sh --apply
scripts/reconcile-keycloak-saml-aws-id-02.sh --check
```

`reconcile-keycloak-saml-aws-id-02.sh`는 existing realm import를 실행하지 않는다. 기존
SAML client에 reader client role·role mapper·전용 group을 추가하고, 기존
`/platform-users`와 `/platform-privileged`의 **직접 membership만 각각 inventory·identity
전용 group으로 복사**한 뒤 legacy client-role mapping을 제거한다. observability/security
group에는 직무명·스크린샷을 근거로 membership을 자동 부여하지 않는다. 기존 OIDC client,
legacy group, 기존 membership은 보존하며 같은 client ID나 top-level group이 정확히 하나가
아니면 fail-closed 한다.

## live 검증과 폐기

실제 SAML assertion·token·계정 ID는 터미널, Git, 로그에 출력하지 않는다. runbook의 검증기는
memory mode `0600` temp file만 쓰고 SHA-256/boolean/HTTP status/role 이름만 출력해야 한다.

1. inventory/identity 전용 group에 이관된 기존 일상/특권 사용자로 TOTP 포함 browser SAML
   로그인을 수행해 각자 배정 role 하나만 AWS console에서 선택 가능한지 확인한다.
2. 다른 role endpoint 또는 `sts:AssumeRole`은 거부되고, group 없는 테스트 ID의 SAML
   assertion에는 AWS Role 값이 없어 console/assume이 거부되는지 확인한다.
3. `sts get-caller-identity`가 `assumed-role`임을 보이고, observer EC2 describe는 성공,
   S3와 IAM 변경은 거부되는지 확인한다. 900초 만료 뒤 같은 temporary credential 호출이
   실패하는지 확인한다.
4. 사람용 IAM user access key 0건, Git·Pod log·검증 log에 account ID·credential·assertion
   원문 0건을 확인한다. 검증용 자원을 만들었다면 모두 제거하고 재-plan 무변경을 확인한다.

이행 rollback은 먼저 `reconcile-keycloak-saml-aws-id-02.sh --rollback`으로 legacy mapping만
되돌린다. 전체 폐기는 Keycloak client를 전용 rollback으로 지워 새 SAML 진입을 멈춘 뒤, 별도
폐기 branch에서 네 `prevent_destroy` block을 명시적으로 해제하고 `tofu destroy` plan을 검토한다.
그때도 backup/VPN root는 plan에 나타나면 안 된다. IdP metadata 또는 signing certificate 교체는
Keycloak metadata를 새 파일로 내려받아 hash·issuer를 확인하고 이 root의 update plan을 승인해
`aws_iam_saml_provider`만 갱신한 뒤 위 로그인·MFA·role·만료 검증을 전부 다시 실행한다.
