#!/usr/bin/env bash
# shellcheck disable=SC2029
set -euo pipefail
umask 077

usage() {
  cat >&2 <<'EOF'
사용법:
  kms-01-seal-migrate.sh status
  kms-01-seal-migrate.sh seal
  kms-01-seal-migrate.sh unseal <현재 Shamir key 파일>
  kms-01-seal-migrate.sh migrate <현재 Shamir 또는 recovery key 파일>
  kms-01-seal-migrate.sh rekey-recovery <현재 recovery key 파일> <새 recovery key 파일>
EOF
  exit 2
}

[ "$#" -ge 1 ] || usage
action=$1
shift

secret_root=${KTC_SECRET_ROOT:-${HOME}/secrets/ktcloud4-bean}
root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
known_hosts=${SSH_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}
kubectl=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=${known_hosts}"
          -o PasswordAuthentication=no -o ControlMaster=no)

check_secret_file() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] \
    || { echo "일반 secret 파일이 필요하다: $file" >&2; exit 1; }
  [ "$(stat -c %a "$file")" = 600 ] \
    || { echo "secret 파일 mode는 0600이어야 한다: $file" >&2; exit 1; }
}

check_key_file() {
  local file=$1
  check_secret_file "$file"
  [ "$(awk 'NF {n++} END {print n+0}' "$file")" -ge 3 ] \
    || { echo "threshold 3을 충족할 key가 없다" >&2; exit 1; }
  awk 'NF && $0 !~ /^[A-Za-z0-9+\/=]+$/ {exit 1}' "$file" \
    || { echo "key 파일 형식이 base64가 아니다" >&2; exit 1; }
}

status() {
  ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault exec vault-0 -- sh -c 'vault status -format=json || test \$? -eq 2'" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("initialized=%s sealed=%s seal_type=%s n=%s t=%s" % (str(d.get("initialized")).lower(), str(d.get("sealed")).lower(), d.get("type"), d.get("n"), d.get("t")))'
}

remote_unseal() {
  ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault exec -i vault-0 -- vault write -format=json sys/unseal -"
}

remote_seal_status() {
  ssh "${ssh_args[@]}" "$k3s_host" \
    "$kubectl -n vault exec vault-0 -- sh -c 'vault status -format=json || test \$? -eq 2'"
}

case "$action" in
  status)
    [ "$#" -eq 0 ] || usage
    status
    ;;

  seal)
    [ "$#" -eq 0 ] || usage
    check_secret_file "$root_token_file"
    sed -n '1p' "$root_token_file" |
      ssh "${ssh_args[@]}" "$k3s_host" \
        "$kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault operator seal >/dev/null'"
    status
    ;;

  unseal)
    [ "$#" -eq 1 ] || usage
    key_file=$1
    check_key_file "$key_file"
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT INT TERM

    remote_seal_status >"$work/before.json"
    start_index=$(python3 - "$work/before.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if not d.get("sealed") or d.get("migration") or d.get("type") != "shamir":
    raise SystemExit("일반 Shamir unseal 대기 상태가 아니다")
progress = d.get("progress", 0)
if not isinstance(progress, int) or not 0 <= progress < 3:
    raise SystemExit("Shamir unseal progress가 threshold 범위 밖이다")
print(progress + 1)
PY
)

    for index in $(seq "$start_index" 3); do
      sed -n "${index}p" "$key_file" |
        python3 -c 'import json,sys; print(json.dumps({"key":sys.stdin.readline().strip()}))' |
        remote_unseal >"$work/response.json"
      python3 - "$work/response.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
x = d.get("data", d)
print("progress=%s sealed=%s" %
      (x.get("progress"), str(x.get("sealed")).lower()))
PY
    done
    status
    ;;

  migrate)
    [ "$#" -eq 1 ] || usage
    key_file=$1
    check_key_file "$key_file"
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT INT TERM

    remote_seal_status >"$work/before.json"
    start_index=$(python3 - "$work/before.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if not d.get("sealed") or not d.get("migration"):
    raise SystemExit("seal migration 대기 상태가 아니다")
progress = d.get("progress", 0)
if not isinstance(progress, int) or not 0 <= progress < 3:
    raise SystemExit("seal migration progress가 threshold 범위 밖이다")
print(progress + 1)
PY
)

    for index in $(seq "$start_index" 3); do
      sed -n "${index}p" "$key_file" |
        python3 -c 'import json,sys; print(json.dumps({"key":sys.stdin.readline().strip(),"migrate":True}))' |
        remote_unseal >"$work/response.json"
      python3 - "$work/response.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
x = d.get("data", d)
print("progress=%s sealed=%s migration=%s" %
      (x.get("progress"), str(x.get("sealed")).lower(), str(x.get("migration")).lower()))
PY
    done
    status
    ;;

  rekey-recovery)
    [ "$#" -eq 2 ] || usage
    old_key_file=$1
    new_key_file=$2
    check_secret_file "$root_token_file"
    check_key_file "$old_key_file"
    [ ! -e "$new_key_file" ] \
      || { echo "새 recovery key 출력 경로가 이미 존재한다: $new_key_file" >&2; exit 1; }
    new_key_dir=$(dirname "$new_key_file")
    [ -d "$new_key_dir" ] && [ ! -L "$new_key_dir" ] \
      || { echo "새 recovery key 출력 directory가 안전하지 않다" >&2; exit 1; }
    [ "$(stat -c %a "$new_key_dir")" = 700 ] \
      || { echo "새 recovery key 출력 directory mode는 0700이어야 한다" >&2; exit 1; }

    work=$(mktemp -d)
    complete=0
    rekey_started=0
    cleanup_rekey() {
      if [ "$complete" -ne 1 ]; then
        rm -f -- "$new_key_file"
        if [ "$rekey_started" -eq 1 ]; then
          sed -n '1p' "$root_token_file" |
            ssh "${ssh_args[@]}" "$k3s_host" \
              "$kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault delete sys/rekey-recovery-key/init >/dev/null'" \
              >/dev/null 2>&1 || true
        fi
      fi
      rm -rf -- "$work"
    }
    trap cleanup_rekey EXIT INT TERM

    sed -n '1p' "$root_token_file" |
      ssh "${ssh_args[@]}" "$k3s_host" \
        "$kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault read -format=json sys/rekey-recovery-key/init'" \
        >"$work/current.json"
    python3 - "$work/current.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
x = d.get("data") or d
if x.get("started"):
    raise SystemExit("이미 진행 중인 recovery rekey가 있다")
PY

    {
      sed -n '1p' "$root_token_file"
      printf '%s\n' '{"secret_shares":5,"secret_threshold":3,"require_verification":true}'
    } | ssh "${ssh_args[@]}" "$k3s_host" \
      "$kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write -format=json sys/rekey-recovery-key/init -'" \
        >"$work/init.json"
    rekey_started=1
    nonce=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); x=d.get("data") or d; print(x["nonce"])' "$work/init.json")
    [[ "$nonce" =~ ^[0-9a-f-]{36}$ ]] || { echo "rekey nonce 형식이 잘못됐다" >&2; exit 1; }

    for index in 1 2 3; do
      {
        sed -n '1p' "$root_token_file"
        NONCE="$nonce" sed -n "${index}p" "$old_key_file" |
          NONCE="$nonce" python3 -c 'import json,os,sys; print(json.dumps({"key":sys.stdin.readline().strip(),"nonce":os.environ["NONCE"]}))'
      } | ssh "${ssh_args[@]}" "$k3s_host" \
        "$kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write -format=json sys/rekey-recovery-key/update -'" \
        >"$work/update.json"
    done

    python3 - "$work/update.json" "$new_key_file" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
x = d.get("data") or d
keys = x.get("keys_base64")
if not x.get("complete") or not x.get("verification_required") or len(keys or []) != 5:
    raise SystemExit("recovery rekey authorization이 완료되지 않았다")
with open(sys.argv[2], "x", encoding="utf-8") as f:
    for key in keys:
        f.write(key + "\n")
os.chmod(sys.argv[2], 0o600)
PY
    verification_nonce=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); x=d.get("data") or d; print(x["verification_nonce"])' "$work/update.json")
    [[ "$verification_nonce" =~ ^[0-9a-f-]{36}$ ]] \
      || { echo "verification nonce 형식이 잘못됐다" >&2; exit 1; }

    for index in 1 2 3; do
      {
        sed -n '1p' "$root_token_file"
        NONCE="$verification_nonce" sed -n "${index}p" "$new_key_file" |
          NONCE="$verification_nonce" python3 -c 'import json,os,sys; print(json.dumps({"key":sys.stdin.readline().strip(),"nonce":os.environ["NONCE"]}))'
      } | ssh "${ssh_args[@]}" "$k3s_host" \
        "$kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write -format=json sys/rekey-recovery-key/verify -'" \
        >"$work/verify.json"
    done
    python3 - "$work/verify.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
x = d.get("data") or d
if not x.get("complete"):
    raise SystemExit("새 recovery key 검증이 완료되지 않았다")
print("recovery-key rekey verified shares=5 threshold=3")
PY
    complete=1
    ;;

  *) usage ;;
esac
