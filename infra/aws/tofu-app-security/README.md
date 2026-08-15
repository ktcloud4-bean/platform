# HR application security root

작업: `AWS-SEC-02`, `AWS-SEC-03`

이 root는 HR 워크로드 전용 보안 통제를 소유한다. 계정 전역 서비스는
`tofu-account-baseline`의 state에 남기며, 여기서는 그 root의 보안 SNS ARN,
CloudTrail ARN·log group name, Access Analyzer ARN 네 output만 읽는다.

## 소유 범위

- Aurora PostgreSQL CloudWatch 로그의 `AUDIT` 이벤트를 Firehose로 전달하는 전용
  Object Lock `COMPLIANCE` S3 bucket. 기본 보존은 4일, Deep Archive 전환은 30일,
  만료는 210일이다.
- shared HR VPC와 계정 default VPC의 CloudWatch `REJECT` Flow Log.
- WORM/Athena 결과 bucket의 versioning·SSE-KMS·Block Public Access·TLS 거부 정책.
- Security Lake Glue catalog를 읽는 Amazon Managed Grafana(SAML, CloudWatch·Athena
  data source, 전용 Athena workgroup).
- CIEM: 90일 IAM unused-access 월간 보고, 사람 승인 Access Key 예외 처리,
  CloudTrail 기반 SAML reader 권한 드리프트 검토, 성공한 `AttachRolePolicy` 경계
  위반 감시와 Slack interactive callback.
- Keycloak session revoke는 VPC Lambda 하나가 기존 VGW의 Keycloak HTTPS만 사용한다.
  IAM·Secrets Manager·SNS 작업은 VPC 밖 CIEM executor가 담당한다.

VPC·subnet·RDS·EKS·CloudTrail bucket·Security Lake data lake·계정 EBS 기본 암호화는
각 원래 root가 계속 소유한다. NAT, public endpoint, public DNS, `0.0.0.0/0` route를
추가하지 않는다.

## AWS-SEC-03 외부 입력과 승인 경계

OpenTofu는 아래 Secrets Manager **객체만** 만들며 `secret_version`을 선언하지 않는다.
값은 저장소·state·plan·로그에 두지 않고, apply 뒤 운영자가 mode `0600` JSON 파일로 주입한다.

| 객체 | JSON key | 소유·용도 |
|---|---|---|
| CIEM Slack secret | `bot_token`, `signing_secret` | Slack App 관리자가 Interactivity·`chat:write` 용도로 주입 |
| Keycloak session secret | `client_id`, `client_secret` | Keycloak 관리자가 `platform` realm의 전용 confidential service client에만 발급 |

`slack_allowed_user_ids`는 버튼 승인자의 Slack user ID allowlist다. 빈 값은 모든 버튼을
거부한다. Callback은 시크릿 값이 없거나 서명이 틀리면 `401`로 fail closed하며, 서명은 맞아도
allowlist 밖 사용자는 `403`으로 거부한다. HTTP callback은 검증·비동기 enqueue만 하므로 3초
안에 응답하고, 실행 결과는 Slack `response_url`에만 보낸다. DynamoDB action key가 같은 버튼의
중복 실행을 막는다.

Keycloak service client에는 `query-users`, `manage-users`만 부여하고 기존 사람·그룹·SAML
role은 바꾸지 않는다. session revoke는 현재 Keycloak session logout과 이미 발급된 AWS SAML
session의 deny만 처리한다. 계정 disable·사용자 생성·기존 membership 변경은 이 작업에 없다.

| 대상 | 유지 | 생성 | 변경·삭제 |
|---|---|---|---|
| 기존 Keycloak 사용자·group·SAML role | 예 | 아니오 | 없음 |
| Keycloak CIEM service client | 해당 없음 | 예 | 기존 client 변경 없음 |
| Slack App secret | 해당 없음 | Secrets Manager 객체만 | 값은 Terraform이 쓰지 않음 |
| 승인된 boundary 위반 actor의 활성 session | 해당 없음 | 아니오 | 사람 버튼 승인 때만 현재 session 종료 |

Keycloak admin API 경로는 현재 AWS source를 막고 있다. live 적용 직전 별도 승인으로만
`10.20.10.0/24`, `10.20.20.0/24`에서 `10.10.20.10:443`으로 향하는 IPsec inbound rule 하나와
Keycloak restricted ingress의 동일 source allowlist 두 항목을 추가한다. 공개 DNS·NAT·Pomerium
route·`0.0.0.0/0` 규칙은 추가하지 않는다. rollback은 이 exact PF rule과 두 source allowlist만
제거해 Keycloak admin API의 기존 `10.10.0.0/16` 내부 경계로 되돌린다.

## 저장소 밖 입력

```bash
input_dir=/home/<operator>/secrets/ktcloud4-bean/aws-sec-02
install -d -m 700 "$input_dir"
curl --fail --silent --show-error \
  https://sso.imcherry5778.xyz/realms/platform/protocol/saml/descriptor \
  -o "$input_dir/keycloak-platform-metadata.xml"
chmod 600 "$input_dir/keycloak-platform-metadata.xml"
cp terraform.tfvars.example "$input_dir/app-security.tfvars"
chmod 600 "$input_dir/app-security.tfvars"
```

`app-security.tfvars`의 metadata 경로만 실제 절대 경로로 바꾼다. account guard는
실행 시점 AWS CLI identity를 `aws_account_id` variable로 주입해 Git·입력 파일에 계정
식별자를 남기지 않는다.

## 적용 순서

```bash
cd infra/aws/tofu-app-security
export TF_VAR_aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
tofu init
tofu plan -var-file=/저장소/밖/app-security.tfvars -out=/저장소/밖/aws-sec-02.tfplan
# saved plan의 delete=0을 확인한 뒤
tofu apply /저장소/밖/aws-sec-02.tfplan
```

Grafana workspace가 만들어진 뒤에는 Keycloak `platform` realm에 해당 workspace의
`/saml/acs`와 metadata entity ID를 가진 SAML client를 등록해야 한다. 이 client는
`role`, `email`, `login`, `name` assertion을 내보내며 `platform-privileged`만 Admin으로
매핑한다. provider가 요구하는 Editor 값은 구성원 0명의 전용 `grafana-amg-editors` group으로
고정해 기존 일상 사용자에게 편집 권한을 주지 않는다. Keycloak 관리자 MFA 입력은 저장소
밖에서만 사용한다.

```bash
endpoint=$(tofu output -raw grafana_workspace_endpoint)
./scripts/provision-keycloak-grafana-saml.sh --apply --workspace-endpoint "$endpoint"
node ./scripts/verify-grafana-saml-login.js \
  --workspace-endpoint "$endpoint" --connect-ip 10.10.20.10 \
  --username imcherry5778-admin \
  --password-file /저장소/밖/keycloak/privileged-password \
  --totp-file /저장소/밖/keycloak/privileged-totp
```

## CIEM 적용 순서

```bash
cd infra/aws/tofu-app-security
export TF_VAR_aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
tofu plan -var-file=/저장소/밖/app-security.tfvars -out=/저장소/밖/aws-sec-03.tfplan
tofu apply /저장소/밖/aws-sec-03.tfplan
```

그 뒤 Slack App 관리자는 output endpoint 뒤에 `/slack/interactivity`를 붙여 Request URL로
등록하고, 위 Slack JSON을 외부 secret 객체에 주입한다. Keycloak 관리자는 전용 service client
secret만 다른 외부 secret 객체에 주입한다. 두 값과 Slack channel·승인자 user ID가 준비되기 전
callback은 의도적으로 fail closed한다.

완료 검증은 callback의 missing-secret `401`, 유효 서명·비승인 사용자 `403`, 승인 사용자 3초 내
ack와 `response_url` 최종 결과, 동일 버튼 idempotency, `/service/` IAM user 네 개의 key 제외와
`GetAccessKeyLastUsed` 기준, `AttachRolePolicy`의 `errorCode` 제외, 모든 CIEM Lambda `Errors`
alarm, Keycloak VPC Lambda의 exact HTTPS egress만 한 번씩 판정한다. 테스트용 access key·policy
attachment·session은 만든 즉시 제거하고 최종 plan이 무변경인지 확인한다.

## 보존·rollback 경계

WORM bucket의 새 객체는 4일 동안 삭제할 수 없다. 검증 marker를 만들면 그 한 객체는
만료 전까지 남고, 만료 뒤 삭제할 수 있다. `tofu destroy`는 실행하지 않는다. 대신
destroy plan에 WORM bucket delete 경로가 존재하되 `prevent_destroy`가 없음을 확인한다.
COMPLIANCE 기간 중 Firehose가 쓴 객체가 남아 있으면 bucket deletion은 AWS에서 거부된다.

Flow Log·Grafana·Athena와 IAM role은 이 root의 명시적 rollback 범위지만, WORM bucket의
보존 객체와 account baseline은 rollback 범위 밖이다.
