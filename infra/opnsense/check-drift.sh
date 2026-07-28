#!/usr/bin/env bash
# OPNsense 의 현재 설정을 받아 Git 사본과 비교한다.
#
# OPNsense 는 Git 이 바꿀 수 없다. 설정 변경은 항상 웹 UI 에서 일어나고,
# 이 스크립트는 그 변경이 Git 에 기록되지 않은 채 남아 있는지를 탐지한다.
# 교정은 하지 않는다 — 방화벽 설정을 자동으로 되돌리면 노드가 고립될 수 있다.
#
# 준비:
#   System → Access → Users → root → API keys → + 로 키를 발급하고
#   아래 환경변수로 넘긴다. 키 파일은 절대 커밋하지 않는다.
#
#     export OPN_KEY=...
#     export OPN_SECRET=...
#
# 사용:
#   ./check-drift.sh              # 차이가 있으면 종료코드 1
#   ./check-drift.sh --update     # 차이를 Git 사본에 반영 (승인)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OPN_URL="${OPN_URL:-https://10.10.10.1}"
COMMITTED="$HERE/config.xml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

if [ -z "${OPN_KEY:-}" ] || [ -z "${OPN_SECRET:-}" ]; then
  echo "OPN_KEY / OPN_SECRET 환경변수가 필요합니다." >&2
  exit 2
fi

# OPNsense 는 자체 서명 인증서를 쓴다. CA 를 신뢰 저장소에 넣었다면
# OPN_CACERT 로 지정하고, 아니면 -k 로 진행한다.
CURL_TLS=(-k)
[ -n "${OPN_CACERT:-}" ] && CURL_TLS=(--cacert "$OPN_CACERT")

echo "→ 현재 설정 조회 ($OPN_URL)"
if ! curl -sf "${CURL_TLS[@]}" -u "$OPN_KEY:$OPN_SECRET" \
      "$OPN_URL/api/core/backup/download/this" -o "$TMP/live.raw.xml"; then
  echo "조회 실패 — URL·자격증명·네트워크를 확인하세요." >&2
  exit 2
fi

echo "→ 정규화 (revision 제거 · 시크릿 마스킹)"
python3 "$HERE/normalize.py" "$TMP/live.raw.xml" -o "$TMP/live.xml" || exit 2

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

  정당한 변경  → ./check-drift.sh --update 후 커밋 (왜 바꿨는지 메시지에)
  부당한 변경  → 웹 UI 에서 되돌린 뒤 다시 실행

이 계층은 자동 교정을 하지 않습니다. 탐지는 자동, 교정은 사람이 판단합니다.
MSG
exit 1
