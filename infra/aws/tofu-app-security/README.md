# HR application security root

작업: `AWS-SEC-02`

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

VPC·subnet·RDS·EKS·CloudTrail bucket·Security Lake data lake·계정 EBS 기본 암호화는
각 원래 root가 계속 소유한다. NAT, public endpoint, public DNS, `0.0.0.0/0` route를
추가하지 않는다.

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

## 보존·rollback 경계

WORM bucket의 새 객체는 4일 동안 삭제할 수 없다. 검증 marker를 만들면 그 한 객체는
만료 전까지 남고, 만료 뒤 삭제할 수 있다. `tofu destroy`는 실행하지 않는다. 대신
destroy plan에 WORM bucket delete 경로가 존재하되 `prevent_destroy`가 없음을 확인한다.
COMPLIANCE 기간 중 Firehose가 쓴 객체가 남아 있으면 bucket deletion은 AWS에서 거부된다.

Flow Log·Grafana·Athena와 IAM role은 이 root의 명시적 rollback 범위지만, WORM bucket의
보존 객체와 account baseline은 rollback 범위 밖이다.
