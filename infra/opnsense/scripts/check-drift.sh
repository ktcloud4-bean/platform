#!/usr/bin/env bash
# OPNsense 의 현재 설정을 받아 Git 사본과 비교한다.
#
# OPNsense 는 Git 이 바꿀 수 없다. 설정 변경은 항상 웹 UI 에서 일어나고,
# 이 스크립트는 그 변경이 Git 에 기록되지 않은 채 남아 있는지를 탐지한다.
# 교정은 하지 않는다 — 방화벽 설정을 자동으로 되돌리면 노드가 고립될 수 있다.
set -euo pipefail

# 호출자가 export한 비밀은 셸 변수 값만 유지하고 즉시 자식 상속을 끊는다.
export -n OPN_KEY OPN_SECRET 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPONENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ENV_FILE="$COMPONENT_DIR/.env"
DEFAULT_OPN_URL="https://opnsense.imcherry5778.xyz"
COMMITTED="$COMPONENT_DIR/config.xml"

UPDATE=0
INSECURE=0
CONNECT_IP=""
ENV_FILE="$DEFAULT_ENV_FILE"
ENV_FILE_EXPLICIT=0

usage() {
  cat <<EOF
사용법: $0 [옵션]

옵션 없이 실행하면 현재 OPNsense 설정과 Git 사본을 비교합니다.

  --update             정규화한 현재 설정으로 Git 사본을 갱신합니다.
  --env-file <파일>    OPN_* 값을 읽을 env 파일을 명시합니다.
                       생략하면 존재할 때만 $DEFAULT_ENV_FILE 을 읽습니다.
  --connect-ip <IPv4>  DNS 대신 지정 IP로 연결하되 hostname 인증서는 검증합니다.
  --insecure           인증서 검증을 끕니다. 비상 조회 전용이며 --update와
                       함께 사용할 수 없습니다.
  -h, --help           이 도움말을 표시합니다.

우선순위는 이미 export된 환경변수 > env 파일 > 안전한 기본값입니다.
env 파일은 source하지 않으며 OPN_KEY, OPN_SECRET, OPN_URL, OPN_CACERT만
읽습니다. OPN_*가 아닌 항목은 export하지 않습니다.
EOF
}

fail() {
  echo "$*" >&2
  exit 2
}

load_env_file() {
  local env_file=$1
  local line trimmed line_number key value mode owner_id
  declare -A seen=()

  [ ! -L "$env_file" ] || fail "env 파일은 심볼릭 링크일 수 없습니다: $env_file"
  [ -f "$env_file" ] || fail "env 파일이 없습니다: $env_file"
  [ -r "$env_file" ] || fail "env 파일을 읽을 수 없습니다: $env_file"

  mode="$(stat -c '%a' "$env_file")"
  owner_id="$(stat -c '%u' "$env_file")"
  [ "$owner_id" = "$(id -u)" ] \
    || fail "env 파일 소유자가 현재 사용자와 다릅니다: $env_file"
  [ $((10#$mode % 100)) -eq 0 ] \
    || fail "env 파일의 group/other 권한을 제거하세요 (권장 600): $env_file (mode $mode)"

  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"

    case "$trimmed" in
      ""|'#'*) continue ;;
    esac

    if [[ "$line" != *=* ]]; then
      [[ "$line" != *OPN_* ]] \
        || fail "$env_file:$line_number: OPN_* 항목은 KEY=VALUE 형식이어야 합니다."
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"

    # 공유 env 파일을 명시해도 OPNsense 입력 외에는 자식 프로세스로 넘기지 않는다.
    [[ "$key" == OPN_* ]] || continue

    case "$key" in
      OPN_KEY|OPN_SECRET|OPN_URL|OPN_CACERT) ;;
      *) fail "$env_file:$line_number: 허용되지 않은 OPN_* 항목입니다: $key" ;;
    esac

    [[ -z "${seen[$key]+x}" ]] \
      || fail "$env_file:$line_number: 중복된 항목입니다: $key"
    seen[$key]=1

    if [[ "$value" == \" || "$value" == \' ]]; then
      fail "$env_file:$line_number: 따옴표가 닫히지 않았습니다: $key"
    elif [[ "$value" == \"*\" && "$value" == *\" ]] \
      || [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \"* || "$value" == *\" \
         || "$value" == \'* || "$value" == *\' ]]; then
      fail "$env_file:$line_number: 따옴표가 닫히지 않았습니다: $key"
    fi

    # 호출자가 명시적으로 export한 값은 파일보다 우선한다.
    if ! [[ -v "$key" ]]; then
      printf -v "$key" '%s' "$value"
    fi
  done < "$env_file"

  echo "→ env 파일 사용 ($env_file)"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update)
      UPDATE=1
      shift
      ;;
    --env-file)
      [ "$#" -ge 2 ] || fail "--env-file 뒤에 파일 경로가 필요합니다."
      ENV_FILE=$2
      ENV_FILE_EXPLICIT=1
      shift 2
      ;;
    --connect-ip)
      [ "$#" -ge 2 ] || fail "--connect-ip 뒤에 IPv4 주소가 필요합니다."
      CONNECT_IP=$2
      shift 2
      ;;
    --insecure)
      INSECURE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "알 수 없는 옵션입니다: $1"
      ;;
  esac
done

if [ "$ENV_FILE_EXPLICIT" -eq 1 ]; then
  load_env_file "$ENV_FILE"
elif [ -f "$ENV_FILE" ]; then
  load_env_file "$ENV_FILE"
fi

OPN_URL="${OPN_URL:-$DEFAULT_OPN_URL}"
OPN_CACERT="${OPN_CACERT:-}"

[ -n "${OPN_KEY:-}" ] && [ -n "${OPN_SECRET:-}" ] \
  || fail "OPN_KEY / OPN_SECRET이 필요합니다. export하거나 --env-file을 지정하세요."
[[ "$OPN_KEY" != *:* ]] || fail "OPN_KEY에는 ':' 문자를 사용할 수 없습니다."
[[ "$OPN_KEY" != *$'\n'* && "$OPN_KEY" != *$'\r'* ]] \
  || fail "OPN_KEY에는 줄바꿈을 사용할 수 없습니다."
[[ "$OPN_SECRET" != *$'\n'* && "$OPN_SECRET" != *$'\r'* ]] \
  || fail "OPN_SECRET에는 줄바꿈을 사용할 수 없습니다."

if [ "$INSECURE" -eq 1 ] && [ "$UPDATE" -eq 1 ]; then
  fail "--insecure 상태에서는 --update할 수 없습니다. 인증된 연결로 다시 실행하세요."
fi
if [ "$INSECURE" -eq 1 ] && [ -n "$OPN_CACERT" ]; then
  fail "--insecure와 OPN_CACERT는 함께 사용할 수 없습니다."
fi
if [ -n "$OPN_CACERT" ]; then
  [ -f "$OPN_CACERT" ] && [ -r "$OPN_CACERT" ] \
    || fail "OPN_CACERT 파일을 읽을 수 없습니다: $OPN_CACERT"
fi

URL_DATA="$(python3 - "$OPN_URL" "$CONNECT_IP" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

url = sys.argv[1]
connect_ip = sys.argv[2]

try:
    parsed = urlsplit(url)
    port = parsed.port or 443
except ValueError as exc:
    raise SystemExit(f"OPN_URL이 올바르지 않습니다: {exc}")

if parsed.scheme != "https" or not parsed.hostname:
    raise SystemExit("OPN_URL은 hostname을 포함한 https URL이어야 합니다.")
if parsed.username or parsed.password:
    raise SystemExit("OPN_URL에 자격증명을 넣을 수 없습니다.")
if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
    raise SystemExit("OPN_URL에는 path, query, fragment를 넣을 수 없습니다.")

resolve = ""
if connect_ip:
    try:
        address = ipaddress.ip_address(connect_ip)
    except ValueError as exc:
        raise SystemExit(f"--connect-ip가 올바른 IP가 아닙니다: {exc}")
    if address.version != 4:
        raise SystemExit("현재 --connect-ip는 IPv4만 지원합니다.")
    try:
        ipaddress.ip_address(parsed.hostname)
    except ValueError:
        pass
    else:
        raise SystemExit("--connect-ip는 hostname OPN_URL과 함께 사용해야 합니다.")
    resolve = f"{parsed.hostname}:{port}:{address}"

base = url.rstrip("/")
endpoint = f"{base}/api/core/backup/download/this"
print(f"{endpoint}\t{resolve}")
PY
)" || fail "OPN_URL 또는 --connect-ip 입력을 확인하세요."

IFS=$'\t' read -r API_URL RESOLVE_ENTRY <<< "$URL_DATA"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

curl_config_escape() {
  local escaped=${1//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '%s' "$escaped"
}

AUTH_CONFIG="$TMP/curl-auth.conf"
umask 077
printf 'user = "%s:%s"\n' \
  "$(curl_config_escape "$OPN_KEY")" \
  "$(curl_config_escape "$OPN_SECRET")" > "$AUTH_CONFIG"
chmod 600 "$AUTH_CONFIG"

CURL_TLS=()
if [ "$INSECURE" -eq 1 ]; then
  CURL_TLS=(-k)
  cat >&2 <<'WARN'
경고: TLS 인증서 검증이 비활성화되었습니다.
중간자 공격 시 OPNsense API key/secret이 노출될 수 있습니다.
이 모드는 비상 조회 전용이며 결과를 --update로 승인할 수 없습니다.
WARN
elif [ -n "$OPN_CACERT" ]; then
  CURL_TLS=(--cacert "$OPN_CACERT")
  echo "→ TLS 인증서 검증 활성화 (지정 CA)"
else
  echo "→ TLS 인증서 검증 활성화 (시스템 trust store)"
fi

CURL_ROUTE=()
if [ -n "$RESOLVE_ENTRY" ]; then
  CURL_ROUTE=(--resolve "$RESOLVE_ENTRY")
  echo "→ DNS 우회 연결 ($CONNECT_IP, hostname 검증 유지)"
fi

echo "→ 현재 설정 조회 ($OPN_URL)"
if ! curl -q --silent --show-error --fail \
      --connect-timeout 10 --max-time 60 --config "$AUTH_CONFIG" \
      "${CURL_TLS[@]}" "${CURL_ROUTE[@]}" \
      "$API_URL" -o "$TMP/live.raw.xml"; then
  cat >&2 <<'MSG'
조회 실패 — URL·자격증명·DNS·TLS·네트워크를 확인하세요.
DNS만 우회하려면 canonical OPN_URL을 유지하고 --connect-ip를 사용하세요.
인증서 검증을 끄는 --insecure는 비상 조회에만 사용하세요.
MSG
  exit 2
fi

echo "→ 정규화 (revision 제거 · 시크릿 마스킹)"
python3 "$SCRIPT_DIR/normalize.py" "$TMP/live.raw.xml" -o "$TMP/live.xml"

if [ ! -f "$COMMITTED" ]; then
  echo "Git 사본이 없습니다. 최초 등록:"
  cp "$TMP/live.xml" "$COMMITTED"
  echo "  → $COMMITTED 생성됨. 커밋하세요."
  exit 0
fi

if diff -u "$COMMITTED" "$TMP/live.xml" > "$TMP/drift.diff"; then
  echo "드리프트 없음 ✓"
  exit 0
fi

echo
echo "════ 드리프트 감지 ════"
cat "$TMP/drift.diff"
echo "═══════════════════════"
echo

if [ "$UPDATE" -eq 1 ]; then
  cp "$TMP/live.xml" "$COMMITTED"
  echo "Git 사본을 갱신했습니다. 변경 이유를 커밋 메시지에 남기세요."
  exit 0
fi

cat <<'MSG'
판단이 필요합니다.

  정당한 변경  → infra/opnsense/scripts/check-drift.sh --update 후 커밋
                  (왜 바꿨는지 메시지에)
  부당한 변경  → 웹 UI 에서 되돌린 뒤 다시 실행

이 계층은 자동 교정하지 않습니다. 탐지는 자동, 교정은 사람이 판단합니다.
MSG
exit 1
