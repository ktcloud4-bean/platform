# AWS Keycloak SAML 임시 콘솔 권한 런북

- 소유 작업: `AWS-ID-01`
- Keycloak realm/issuer: `platform` / `https://sso.imcherry5778.xyz`
- AWS 방식: IAM SAML provider + `sts:AssumeRoleWithSAML` (IAM Identity Center가 아님)
- 선언 root: [`infra/aws/tofu-identity`](../../infra/aws/tofu-identity/)

## 경계와 사전 판정

SAML browser flow는 사용자의 browser가 Keycloak assertion을 AWS sign-in endpoint로 전송한다.
AWS가 Keycloak으로 직접 연결하지 않는다. 따라서 이 작업은 SSO public exposure, VLAN route,
OPNsense PF/NAT, Site-to-Site VPN의 변경을 요구하지 않는다. 그런 변경이 필요하다는 결과가
나오면 적용을 멈추고 `AWS-ID-01` 범위 밖 차이로 보고한다.

다음은 각각 독립 state다.

| root | 소유 대상 | AWS-ID-01에서의 규칙 |
|---|---|---|
| `infra/aws/tofu` | 오프사이트 backup bucket, 전송 service identity/access key | 읽기·변경·import 금지. bucket access 권한도 SAML role에 부여하지 않음 |
| `infra/aws/tofu-network` | VPC, VGW, Site-to-Site VPN | 읽기·변경·import 금지. VPN Connection gate를 건드리지 않음 |
| `infra/aws/tofu-identity` | Keycloak SAML provider, 사람용 임시 IAM role | 이 런북과 AWS-ID-01만 소유 |

기존 `seaweedfs-offsite-backup` access key는 backup service identity다. 이 작업의
"지속 access key 없음" 검증은 사람용 IAM user에 한정한다. 새 IAM user/access key는 만들지
않으며 `admin` 등 사람용 IAM user의 access key는 0개여야 한다.

## 승인 전 읽기 전용 preflight

출력에서 계정 ID, SAML metadata XML, assertion, access key, token을 그대로 보이지 않는다.

```sh
aws sts get-caller-identity --output json \
  | jq '{account:(.Account|gsub("[0-9]";"*")), arn:(.Arn|gsub("[0-9]";"*"))}'
aws iam list-saml-providers --output json \
  | jq '{count:(.SAMLProviderList|length), names:[.SAMLProviderList[].Arn|split("/")[1]]}'
aws iam list-roles --output json \
  | jq '{names:[.Roles[].RoleName|select(startswith("platform-saml-"))]}'
```

Keycloak은 기존 `KC-01` 검증기를 먼저 통과해야 한다. 이 단계는 OIDC client, group, user를
변경하지 않는다.

```sh
export KC01_SECRET_DIR=/home/<operator>/secrets/ktcloud4-bean/keycloak
gitops/tools/kc-01/verify-live.sh
```

다음 조건이 모두 맞을 때만 plan을 만든다.

- issuer가 고정 값이고 daily/privileged login 모두 TOTP 없이는 거부된다.
- daily는 `/platform-users`만, privileged는 `/platform-privileged`와
  `/keycloak-readers`만 가진다. `kc-verify`는 그대로 `fullScopeAllowed=false`다.
- 새 SAML provider와 `platform-saml-*` role이 없다. 같은 이름이 이미 있다면 import하거나
  덮어쓰지 않고 중단한다.
- `AWS-ID-01`을 선행으로 갖는 후속 작업은 없음을 현재 backlog에서 다시 확인한다.

## 계획과 apply gate

실제 변수와 metadata는 저장소 밖 mode `0600`에만 둔다. 아래 명령의 표준 출력은 화면에
원문 metadata나 account ID가 남지 않도록 `/dev/null`로 버리고, binary plan의 대상 주소와
action 수만 출력한다.

```sh
export AWS_ID01_SECRET_DIR=/home/<operator>/secrets/ktcloud4-bean/aws-id-01
install -d -m 700 "$AWS_ID01_SECRET_DIR"
curl --fail --silent --show-error \
  https://sso.imcherry5778.xyz/realms/platform/protocol/saml/descriptor \
  >"$AWS_ID01_SECRET_DIR/keycloak-platform-metadata.xml"
chmod 600 "$AWS_ID01_SECRET_DIR/keycloak-platform-metadata.xml"

# 실제 account ID를 외부 tfvars에만 둔다.
cp infra/aws/tofu-identity/terraform.tfvars.example "$AWS_ID01_SECRET_DIR/identity.tfvars"
chmod 600 "$AWS_ID01_SECRET_DIR/identity.tfvars"
# 사람은 editor로 위 파일의 aws_account_id와 saml_metadata_file만 채운다.

cd infra/aws/tofu-identity
tofu fmt -check -recursive
tofu init -backend-config="path=$AWS_ID01_SECRET_DIR/terraform.tfstate"
tofu validate
tofu plan -input=false -var-file="$AWS_ID01_SECRET_DIR/identity.tfvars" \
  -out="$AWS_ID01_SECRET_DIR/identity.tfplan" >/dev/null
tofu show -json "$AWS_ID01_SECRET_DIR/identity.tfplan" | jq '{
  actions: ([.resource_changes[].change.actions[]] | sort | group_by(.) | map({action:.[0],count:length})),
  addresses: [.resource_changes[].address] | sort
}'
```

승인자가 확인할 정확한 target은 provider 1개, role 2개, inline policy 2개뿐이다.

```text
aws_iam_saml_provider.keycloak_platform
aws_iam_role.observer
aws_iam_role.identity_reader
aws_iam_role_policy.observer_permissions
aws_iam_role_policy.identity_reader_permissions
```

`create=5`, `change=0`, `destroy=0` 및 backup/VPN 주소 0개가 아니면 적용하지 않는다.
적용 전 롤백 지점은 Git branch와 아직 만들지 않은 IAM/Keycloak 객체다. apply 직후 오류가
나면 새 SAML client만 `reconcile-keycloak-saml.sh --rollback`으로 제거하고, IAM 삭제는
`prevent_destroy` 보호를 유지한 채 별도 폐기 plan으로만 다룬다.

사람의 명시적 승인 뒤에만 실행한다.

```sh
tofu apply "$AWS_ID01_SECRET_DIR/identity.tfplan"
tofu plan -input=false -var-file="$AWS_ID01_SECRET_DIR/identity.tfvars" >/dev/null
```

## Keycloak client 반영

`reconcile-keycloak-saml.sh`는 기존 realm을 import/recreate하지 않는다. 새 `https://signin.aws.amazon.com/saml`
SAML client에 아래만 만들고 현재 두 group에 새 client role mapping만 추가한다. client ID와
`Audience`는 전역 AWS sign-in URI를 사용하지만, AWS trust의 `SAML:aud` 판정값은
`SubjectConfirmationData Recipient`이므로 서울 ACS URI를 사용한다.

| mapper/설정 | 값 |
|---|---|
| `aws-role-list` | AWS `Role` attribute, URI Reference, single attribute |
| `aws-*-role-name` | client role을 role ARN + provider ARN pair로 변환 |
| `aws-role-session-name` | built-in `username` → `RoleSessionName` |
| `aws-session-duration` | `SessionDuration=900` |
| `aws-console-audience` | `https://signin.aws.amazon.com/saml` (SAML `Audience`) |
| SAML POST ACS / Recipient | `https://ap-northeast-2.signin.aws.amazon.com/saml` (IAM trust `SAML:aud`) |
| group mapping | `/platform-users`→observer, `/platform-privileged`→identity-reader |

Keycloak이 SAML client 생성 때 자동 연결하는 공용 `role_list` client scope는 이 전용 client에서만
분리한다. 그렇지 않으면 AWS URI Role mapper와 기본 `Role` mapper가 충돌해 assertion의 AWS
Role attribute가 덮인다. 공용 scope 원문과 다른 client의 연결은 변경하지 않는다.

다른 existing group 속성·membership, existing OIDC client, existing user는 변경하지 않는다.
그룹에 없는 임시 검증 ID는 생성 후 삭제하며, 기존 ID의 group을 시험 목적으로 바꾸지 않는다.
IdP-initiated URL은 client의 `baseUrl`, exact redirect URI, SAML POST assertion consumer URL을
Seoul AWS sign-in ACS로 같게 둔다. 이 값이 누락된 구버전 적용은 소유 표식을 확인하는
`--repair`만 한 번 실행해 보정한다.

```sh
# tofu sensitive output은 화면에 출력하지 않고 외부 0600 파일/환경으로만 넘긴다.
export KC01_SECRET_DIR=/home/<operator>/secrets/ktcloud4-bean/keycloak
export AWS_ID01_SAML_PROVIDER_ARN="$(<"$AWS_ID01_SECRET_DIR/provider-arn")"
export AWS_ID01_OBSERVER_ROLE_ARN="$(<"$AWS_ID01_SECRET_DIR/observer-role-arn")"
export AWS_ID01_IDENTITY_READER_ROLE_ARN="$(<"$AWS_ID01_SECRET_DIR/identity-reader-role-arn")"
infra/aws/tofu-identity/scripts/reconcile-keycloak-saml.sh --apply
infra/aws/tofu-identity/scripts/reconcile-keycloak-saml.sh --check
```

## live 완료 검증

각 assertion은 mode `0600` 임시 file에서만 decode하고 즉시 삭제한다. assertion 원문은
shell 인자, CI log, Git, terminal에 출력하지 않는다.

1. daily와 privileged로 각각 browser SAML login을 수행한다. TOTP 누락은 Keycloak에서
   거부되고, 올바른 TOTP는 AWS console POST까지 성공해야 한다.
2. daily assertion에는 observer ARN pair 하나, privileged assertion에는 identity-reader
   pair 하나만 존재하는지 SHA-256/개수 비교로 검증한다. 반대 role ARN은 없어야 한다.
3. group 없는 임시 platform user(필수 TOTP)를 만들고 SAML flow를 실행한다. 새 user가
   최초 TOTP 등록/필수 profile 화면을 보이면 **그 임시 user에만** QR 기반 TOTP 등록과 profile
   입력을 마친다. seed·QR·assertion 원문은 출력하거나 Git에 남기지 않는다. 이어 assertion에
   AWS Role attribute가 없어 AWS console/`AssumeRoleWithSAML`이 거부되는 것을 확인한 뒤 user와
   모든 temp file을 삭제한다.
4. positive assertion으로 `sts assume-role-with-saml`을 호출해 external mode `0600`
   credential file을 만든다. 그 profile의 `sts get-caller-identity` ARN은
   `assumed-role/platform-saml-*` 형식이어야 하며 account 숫자는 mask해 출력한다.
5. observer의 `ec2 describe-vpn-connections`는 성공하고, `s3api list-buckets`,
   `iam list-users`, `sts assume-role`(반대 role)은 모두 `AccessDenied`여야 한다.
   identity-reader는 이 SAML provider/두 role 읽기만 성공하고 IAM 변경은 거부되어야 한다.
6. credential의 expiration을 기록한 뒤 900초가 지난 시점에 동일 profile의
   `sts get-caller-identity`가 expired-token 계열 오류로 실패하는지 확인한다. 대기 중에는
   이 작업 외 변경을 하지 않는다.
7. 사람용 IAM user access key 수가 0, Git/Keycloak Pod/검증 로그의 account ID·credential·
   assertion 원문 수가 0인지 확인한다. 검증용 user/profile/temp file을 전부 제거하고
   `tofu plan`이 무변경인지 다시 확인한다.

## metadata·인증서 회전과 rollback

Keycloak signing key 또는 IdP metadata가 바뀌면 AWS는 자동 갱신하지 않는다.

1. Keycloak realm metadata endpoint에서 새 XML을 외부 mode `0600` file로 내려받아 issuer와
   SHA-256만 확인한다.
2. `tofu plan`이 `aws_iam_saml_provider.keycloak_platform` update 하나만 제시하는지 확인하고
   승인 후 apply한다. 기존 role, backup root, VPN root가 있으면 중단한다.
3. 위 TOTP·positive/negative role·권한·15분 만료 검증을 모두 다시 수행한다.

SAML 경로 자체를 폐기할 때는 먼저 전용 Keycloak client를 rollback해 새 assertion 발급을
멈춘다. 그 후 별도 폐기 branch에서 IAM resource의 `prevent_destroy`를 명시적으로 해제하고
이 root만의 destroy plan을 승인한다. 기존 backup/VPN state와 리소스는 어떤 폐기 단계에도
포함되면 안 된다.
