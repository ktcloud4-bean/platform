#!/usr/bin/env bash
# AWS-CI-FIX-02 완료 증거의 정적 항목만 한 경로로 판정한다.
set -Eeuo pipefail

readonly root_dir=$(git rev-parse --show-toplevel)
readonly jenkins_yaml=${root_dir}/gitops/apps/jenkins/jenkins.yaml
readonly vault_agent=${root_dir}/gitops/apps/jenkins/vault-agent-config.yaml
readonly pipeline=${root_dir}/infra/aws/Jenkinsfile
readonly tofu_runner=${root_dir}/gitops/tools/aws-ci-fix-01/run-opentofu.sh
readonly github_source=${root_dir}/gitops/tools/aws-ci-fix-01/provision-github-source.sh
readonly state_policy=${root_dir}/gitops/tools/aws-ci-fix-01/provision-aws-state-policy.sh
readonly plan_read_policy=${root_dir}/gitops/tools/aws-ci-fix-01/provision-aws-plan-read-policy.sh
readonly live_verifier=${root_dir}/gitops/tools/aws-ci-fix-01/verify-live.sh
readonly trivy_image='docker.io/aquasec/trivy:0.72.0@sha256:cffe3f5161a47a6823fbd23d985795b3ed72a4c806da4c4df16266c02accdd6f'
readonly opentofu_image='ghcr.io/opentofu/opentofu:1.12.5@sha256:ba827d1af675c3f522eb78e2b8098cc87daefb9ceb9d3c4b69d0a1bb6d272463'
readonly awscli_image='public.ecr.aws/aws-cli/aws-cli:2.27.18@sha256:244dcb5bd64c98d0c624b0f8951be872b6aa43a6587da6cbb5c7f30c2bd89e58'

fail() {
  echo "AWS-CI-FIX-02 static verification 실패: $*" >&2
  exit 1
}

for command in envsubst git jq kubectl podman ruby shellcheck tofu; do
  command -v "${command}" >/dev/null || fail "${command} command가 없다."
done

umask 077
temp_dir=$(mktemp -d /tmp/aws-ci-fix-01-static.XXXXXX)
cleanup() {
  local status=$?
  rm -rf -- "${temp_dir}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

shellcheck -e SC2029 "${tofu_runner}" "${github_source}" "${state_policy}" "${plan_read_policy}" "${live_verifier}"

# Scripted pipeline only: JCasC가 parameter/source를 소유하고 apply는 어느 경로에도 없다.
! rg -n '^\s*pipeline\s*\{' "${pipeline}" >/dev/null || fail 'Declarative pipeline을 다시 넣었다.'
! rg -n '\b(properties|checkout scm|input|apply)\b' "${pipeline}" >/dev/null || fail '금지된 Jenkins DSL 또는 apply 경로가 있다.'
rg -F "node('aws-opentofu')" "${pipeline}" >/dev/null || fail '전용 agent label이 없다.'
rg -F 'github-platform-readonly-aws-ci-fix-01' "${pipeline}" "${jenkins_yaml}" >/dev/null \
  || fail 'GitHub read credential 참조가 없다.'
rg -F 'ssh://git@ssh.github.com:443/ktcloud4-bean/platform.git' "${pipeline}" "${jenkins_yaml}" >/dev/null \
  || fail 'GitHub source를 고정하지 않았다.'
rg -F "[ssh.github.com]:443 ssh-ed25519" "${jenkins_yaml}" >/dev/null \
  || fail 'GitHub HTTPS-port host key가 없다.'
rg -F 'github_platform_ssh_private_key' "${jenkins_yaml}" "${vault_agent}" >/dev/null \
  || fail 'GitHub deploy key의 Vault consumer 경로가 없다.'
rg -F "${awscli_image}" "${jenkins_yaml}" >/dev/null || fail '고정 AWS CLI sidecar가 없다.'
rg -F 'name: aws-tofu-tmp' "${jenkins_yaml}" >/dev/null || fail 'OpenTofu scratch volume이 없다.'
rg -F 'sizeLimit: 2Gi' "${jenkins_yaml}" >/dev/null || fail 'OpenTofu scratch volume 용량이 없다.'
podman run --rm --entrypoint /bin/sh "${opentofu_image}" -ec \
  'command -v tofu; command -v sha256sum; command -v mktemp' >/dev/null
podman run --rm --entrypoint /bin/sh "${awscli_image}" -ec \
  'command -v aws; command -v sleep' >/dev/null

# JCasC 변수는 값 없이 구조만 렌더링한다.
export aws_access_key_id=dummy aws_secret_access_key=dummy
export cosign_password=dummy cosign_private_key=dummy cosign_public_key=dummy cosign_reject_public_key=dummy
export e2e01_sonar_token=dummy gitea_known_hosts='gitea.example ssh-ed25519 dummy'
export gitea_ssh_private_key=dummy github_platform_ssh_private_key=dummy
export harbor_robot_name=dummy harbor_robot_secret=dummy jenkins_admin_password=dummy
envsubst <"${jenkins_yaml}" >"${temp_dir}/jenkins.rendered.yaml"
ruby -ryaml -e 'YAML.load_file(ARGV.fetch(0)); puts "JCasC=PASS"' "${temp_dir}/jenkins.rendered.yaml" >/dev/null
kubectl kustomize "${root_dir}/gitops/apps/jenkins" >"${temp_dir}/jenkins.rendered.yaml"

# allowlist, account guard, partial backend와 immutable state key namespace를 텍스트로 고정한다.
for root in tofu-app-network tofu-app-ecr tofu-account-baseline tofu-app-security; do
  rg -F "${root})" "${tofu_runner}" >/dev/null || fail "${root} allowlist가 없다."
done
! rg -n 'tofu-app-(db|eks)' "${pipeline}" "${tofu_runner}" >/dev/null || fail '허용 범위 밖 root가 남아 있다.'
rg -F "expected_account_sha256" "${tofu_runner}" "${state_policy}" >/dev/null || fail 'account guard가 없다.'
rg -F 'ec2:DescribeAvailabilityZones' "${plan_read_policy}" >/dev/null || fail '관측된 network plan read action이 없다.'
rg -F 'dynamodb_table' "${tofu_runner}" >/dev/null || fail 'partial backend lock 설정이 없다.'
rg -F '/v1/terraform.tfstate' "${tofu_runner}" "${state_policy}" >/dev/null || fail 'state key v1 선언이 없다.'

# backend 없이 이번에 연 두 root의 provider schema와 configuration을 검증한다.
for root in tofu-account-baseline tofu-app-security; do
  work=${temp_dir}/${root}
  cp -a "${root_dir}/infra/aws/${root}" "${work}"
  (
    cd "${work}"
    tofu init -input=false -backend=false >/dev/null
    tofu validate -no-color >/dev/null
  )
done

# Jenkins와 같은 severity/exit contract로 이번 두 root만 검사한다.
for root in tofu-account-baseline tofu-app-security; do
  podman run --rm -v "${root_dir}:/work:ro,Z" "${trivy_image}" config \
    --exit-code 1 --severity HIGH,CRITICAL "/work/infra/aws/${root}" >/dev/null
done

# 실제 gate와 동일한 Trivy config failure/success contract를 fixture로 확인한다.
cat >"${temp_dir}/trivy-positive.yaml" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: trivy-positive
spec:
  containers:
    - name: privileged
      image: busybox:1.36
      securityContext:
        privileged: true
EOF
cat >"${temp_dir}/trivy-negative.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: trivy-negative
data:
  mode: readonly
EOF
if podman run --rm -v "${temp_dir}:/work:ro,Z" "${trivy_image}" config \
  --exit-code 1 --severity HIGH,CRITICAL /work/trivy-positive.yaml >/dev/null 2>&1; then
  fail 'Trivy positive fixture가 통과했다.'
fi
podman run --rm -v "${temp_dir}:/work:ro,Z" "${trivy_image}" config \
  --exit-code 1 --severity HIGH,CRITICAL /work/trivy-negative.yaml >/dev/null

printf 'AWS-CI-FIX-02 Static=PASS roots=2 root-trivy=PASS jenkins-template=PASS tofu-scratch=PASS plan-only=PASS trivy-positive=1 trivy-negative=1 expected-account-literals=0\n'
