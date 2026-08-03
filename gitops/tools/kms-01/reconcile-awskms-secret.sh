#!/usr/bin/env bash
# shellcheck disable=SC2029
set -euo pipefail
umask 077

usage() {
  echo "사용법: KTC_SECRET_ROOT=<저장소 밖 root> $0 --check|--apply" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
mode=$1
case "$mode" in
  --check|--apply) ;;
  *) usage ;;
esac

secret_root=${KTC_SECRET_ROOT:-${HOME}/secrets/ktcloud4-bean}
secret_dir=${secret_root}/kms-01
env_file=${secret_dir}/env
k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
known_hosts=${SSH_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}
kubectl=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=${known_hosts}"
          -o PasswordAuthentication=no -o ControlMaster=no)

[ -d "$secret_dir" ] || { echo "kms-01 secret directory가 없다" >&2; exit 1; }
[ ! -L "$secret_dir" ] || { echo "kms-01 secret directory symlink는 허용하지 않는다" >&2; exit 1; }
[ "$(stat -c %a "$secret_dir")" = 700 ] \
  || { echo "kms-01 secret directory mode는 0700이어야 한다" >&2; exit 1; }
[ -f "$env_file" ] && [ ! -L "$env_file" ] \
  || { echo "kms-01 env는 일반 파일이어야 한다" >&2; exit 1; }
[ "$(stat -c %a "$env_file")" = 600 ] \
  || { echo "kms-01 env mode는 0600이어야 한다" >&2; exit 1; }

python3 - "$env_file" <<'PY'
import re, sys

path = sys.argv[1]
entries = {}
for raw in open(path, encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit("kms-01 env 형식이 key=value가 아니다")
    key, value = line.split("=", 1)
    if key in entries:
        raise SystemExit("kms-01 env에 중복 key가 있다")
    entries[key] = value

if set(entries) != {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"}:
    raise SystemExit("kms-01 env는 AWS_ACCESS_KEY_ID와 AWS_SECRET_ACCESS_KEY만 가져야 한다")
if not re.fullmatch(r"[A-Z0-9]{16,128}", entries["AWS_ACCESS_KEY_ID"]):
    raise SystemExit("AWS_ACCESS_KEY_ID 형식이 잘못됐다")
if not re.fullmatch(r"[A-Za-z0-9/+=]{32,256}", entries["AWS_SECRET_ACCESS_KEY"]):
    raise SystemExit("AWS_SECRET_ACCESS_KEY 형식이 잘못됐다")
PY

if [ "$mode" = --apply ]; then
  ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault create secret generic vault-awskms --from-env-file=/dev/stdin --dry-run=client -o yaml | $kubectl apply -f -" \
    <"$env_file" >/dev/null
fi

remote_secret=$(mktemp)
trap 'rm -f -- "$remote_secret"' EXIT INT TERM
ssh "${ssh_args[@]}" "$k3s_host" \
  "$kubectl -n vault get secret vault-awskms -o json" >"$remote_secret"

python3 - "$env_file" "$remote_secret" <<'PY'
import base64, json, sys

expected = {}
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip("\n")
    if line and not line.startswith("#"):
        key, value = line.split("=", 1)
        expected[key] = value.encode()

actual_json = json.load(open(sys.argv[2], encoding="utf-8"))
actual = {key: base64.b64decode(value, validate=True)
          for key, value in actual_json.get("data", {}).items()}
if set(actual) != set(expected):
    raise SystemExit("vault-awskms Secret key 집합이 외부 원본과 다르다")
if any(actual[key] != expected[key] for key in expected):
    raise SystemExit("vault-awskms Secret 값이 외부 원본과 다르다")
print("vault-awskms Secret exact match")
PY
