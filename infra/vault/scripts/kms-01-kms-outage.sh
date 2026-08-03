#!/usr/bin/env bash
# KMS-01 완료 증거: IAM inline policy 회수 한 방법으로만 KMS 장애를 만든다.
# shellcheck disable=SC2029
set -euo pipefail
umask 077

secret_root=${KTC_SECRET_ROOT:-${HOME}/secrets/ktcloud4-bean}
kms_dir=${secret_root}/kms-01
k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
known_hosts=${SSH_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}
kubectl=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
kms_alias=alias/ktcloud4-bean-vault-auto-unseal
ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=${known_hosts}"
          -o PasswordAuthentication=no -o ControlMaster=no)
tofu=(mise exec opentofu@1.12.5 -- tofu -chdir=infra/aws/tofu-kms)

[ -d "$kms_dir" ] && [ ! -L "$kms_dir" ] && [ "$(stat -c %a "$kms_dir")" = 700 ] \
  || { echo "kms-01 외부 directory가 안전하지 않다" >&2; exit 1; }
secret_file=$kms_dir/env
[ -f "$secret_file" ] && [ ! -L "$secret_file" ] && \
  [ "$(stat -c %a "$secret_file")" = 600 ] \
  || { echo "외부 보관 자산이 없거나 권한이 안전하지 않다" >&2; exit 1; }

account_id=$(aws sts get-caller-identity --query Account --output text)
[[ "$account_id" =~ ^[0-9]{12}$ ]] \
  || { echo "AWS account guard를 계산하지 못했다" >&2; exit 1; }
export TF_VAR_aws_account_id=$account_id

root_target=$(ssh "${ssh_args[@]}" "$k3s_host" \
  "$kubectl -n argocd get application platform-root -o jsonpath='{.spec.source.targetRevision}'")
[ "$root_target" = 6b0b9b1126d413cf6f33931daf4f12105ba20c7f ] \
  || { echo "ARGO-ROOT가 KMS-01 pointer SHA를 소유하지 않는다" >&2; exit 1; }
[ -z "$(ssh "${ssh_args[@]}" "$k3s_host" \
  "$kubectl get namespace cert-manager --ignore-not-found -o name")" ] \
  || { echo "cert-manager live window와 겹친다" >&2; exit 1; }

initial_status=$(infra/vault/scripts/kms-01-seal-migrate.sh status)
grep -Fq 'sealed=false seal_type=awskms' <<<"$initial_status" \
  || { echo "$initial_status"; exit 1; }
old_uid=$(ssh "${ssh_args[@]}" "$k3s_host" \
  "$kubectl -n vault get pod vault-0 -o jsonpath='{.metadata.uid}'")

kms_service_probe() {
  local stdout_file=$1
  local stderr_file=$2
  (
    set -a
    # shellcheck disable=SC1091
    source "$kms_dir/env"
    set +a
    AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2 \
      aws kms describe-key --key-id "$kms_alias" \
        >"$stdout_file" 2>"$stderr_file"
  )
}

restore_needed=0
restore_policy() {
  trap - EXIT INT TERM
  if [ "$restore_needed" -eq 1 ]; then
    export TF_VAR_enable_vault_kms_access=true
    "${tofu[@]}" plan -input=false -no-color \
      -out="$kms_dir/emergency-restore.tfplan" >"$kms_dir/emergency-restore-plan.log"
    chmod 600 "$kms_dir/emergency-restore.tfplan" "$kms_dir/emergency-restore-plan.log"
    "${tofu[@]}" apply -input=false -no-color "$kms_dir/emergency-restore.tfplan" \
      >"$kms_dir/emergency-restore-apply.log"
    chmod 600 "$kms_dir/emergency-restore-apply.log"
    restore_needed=0
  fi
}
trap restore_policy EXIT INT TERM

export TF_VAR_enable_vault_kms_access=false
"${tofu[@]}" plan -input=false -no-color -out="$kms_dir/outage.tfplan" \
  >"$kms_dir/outage-plan.log"
chmod 600 "$kms_dir/outage.tfplan" "$kms_dir/outage-plan.log"
changes=$("${tofu[@]}" show -json "$kms_dir/outage.tfplan" |
  jq -r '[.resource_changes[] | select(.change.actions != ["no-op"]) |
          [.address,(.change.actions|join("/"))]]')
[ "$(jq 'length' <<<"$changes")" -eq 1 ]
[ "$(jq -r '.[0][0]' <<<"$changes")" = 'aws_iam_user_policy.vault_auto_unseal[0]' ]
[ "$(jq -r '.[0][1]' <<<"$changes")" = delete ]
"${tofu[@]}" apply -input=false -no-color "$kms_dir/outage.tfplan" \
  >"$kms_dir/outage-apply.log"
chmod 600 "$kms_dir/outage-apply.log"
restore_needed=1

denied=0
for index in $(seq 1 60); do
  set +e
  kms_service_probe "$kms_dir/kms-denied-probe.out" "$kms_dir/kms-denied-probe.err"
  probe_rc=$?
  set -e
  chmod 600 "$kms_dir/kms-denied-probe.out" "$kms_dir/kms-denied-probe.err"
  if [ "$probe_rc" -ne 0 ] && grep -Fq AccessDenied "$kms_dir/kms-denied-probe.err"; then
    denied=1
    break
  fi
  [ "$index" -lt 60 ] || break
  sleep 2
done
[ "$denied" -eq 1 ] || { echo "IAM 회수 전파를 확인하지 못했다" >&2; exit 1; }

ssh "${ssh_args[@]}" "$k3s_host" \
  "$kubectl -n vault delete pod vault-0 --wait=true --timeout=120s" >/dev/null

new_uid=
for index in $(seq 1 60); do
  new_uid=$(ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault get pod vault-0 -o jsonpath='{.metadata.uid}'" 2>/dev/null || true)
  if [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ]; then
    break
  fi
  [ "$index" -lt 60 ] || { echo "Vault Pod가 재생성되지 않았다" >&2; exit 1; }
  sleep 2
done

startup_denied=0
for index in $(seq 1 60); do
  {
    ssh "${ssh_args[@]}" "$k3s_host" "$kubectl -n vault logs vault-0" 2>/dev/null || true
    ssh "${ssh_args[@]}" "$k3s_host" "$kubectl -n vault logs vault-0 --previous" 2>/dev/null || true
  } >"$kms_dir/vault-kms-outage.log"
  chmod 600 "$kms_dir/vault-kms-outage.log"
  ready=$(ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault get pod vault-0 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" \
    2>/dev/null || true)
  if grep -Fq AccessDenied "$kms_dir/vault-kms-outage.log" &&
     grep -Eiq 'awskms|kms' "$kms_dir/vault-kms-outage.log" &&
     [ "$ready" != True ]; then
    startup_denied=1
    break
  fi
  [ "$index" -lt 60 ] || break
  sleep 2
done
[ "$startup_denied" -eq 1 ] \
  || { echo "KMS AccessDenied startup failure를 확인하지 못했다" >&2; exit 1; }

export TF_VAR_enable_vault_kms_access=true
"${tofu[@]}" plan -input=false -no-color -out="$kms_dir/restore.tfplan" \
  >"$kms_dir/restore-plan.log"
chmod 600 "$kms_dir/restore.tfplan" "$kms_dir/restore-plan.log"
changes=$("${tofu[@]}" show -json "$kms_dir/restore.tfplan" |
  jq -r '[.resource_changes[] | select(.change.actions != ["no-op"]) |
          [.address,(.change.actions|join("/"))]]')
[ "$(jq 'length' <<<"$changes")" -eq 1 ]
[ "$(jq -r '.[0][0]' <<<"$changes")" = 'aws_iam_user_policy.vault_auto_unseal[0]' ]
[ "$(jq -r '.[0][1]' <<<"$changes")" = create ]
"${tofu[@]}" apply -input=false -no-color "$kms_dir/restore.tfplan" \
  >"$kms_dir/restore-apply.log"
chmod 600 "$kms_dir/restore-apply.log"
restore_needed=0

available=0
for index in $(seq 1 60); do
  set +e
  kms_service_probe "$kms_dir/kms-restored-probe.out" "$kms_dir/kms-restored-probe.err"
  probe_rc=$?
  set -e
  chmod 600 "$kms_dir/kms-restored-probe.out" "$kms_dir/kms-restored-probe.err"
  if [ "$probe_rc" -eq 0 ]; then
    available=1
    break
  fi
  [ "$index" -lt 60 ] || break
  sleep 2
done
[ "$available" -eq 1 ] || { echo "IAM 복구 전파를 확인하지 못했다" >&2; exit 1; }

recovered=0
for index in $(seq 1 90); do
  current_uid=$(ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault get pod vault-0 -o jsonpath='{.metadata.uid}'" 2>/dev/null || true)
  ready=$(ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault get pod vault-0 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" \
    2>/dev/null || true)
  current_status=$(infra/vault/scripts/kms-01-seal-migrate.sh status 2>/dev/null || true)
  if [ "$current_uid" = "$new_uid" ] && [ "$ready" = True ] &&
     grep -Fq 'sealed=false seal_type=awskms' <<<"$current_status"; then
    recovered=1
    break
  fi
  [ "$index" -lt 90 ] || break
  sleep 2
done
[ "$recovered" -eq 1 ] || { echo "IAM 복구 뒤 Vault가 auto-unseal되지 않았다" >&2; exit 1; }
trap - EXIT INT TERM

echo "kms-outage-method=iam-inline-policy-removal"
echo "kms-outage-propagation=service-credential-access-denied"
echo "vault-startup=access-denied-not-ready"
echo "rollback=create-only-iam-inline-policy"
echo "recovery=same-pod-auto-unsealed-without-share"
echo "pod-recreations=1"
