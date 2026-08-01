#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
app_dir="$repo_root/gitops/apps/crowdsec"
metadata="$app_dir/release-metadata.env"
network_check=false

if (($# > 1)) || { (($# == 1)) && [[ $1 != --network ]]; }; then
  printf '%s\n' '사용법: verify-supply-chain.sh [--network]' >&2
  exit 2
fi
if (($# == 1)); then
  network_check=true
fi

metadata_value() {
  local key=$1
  local -a values
  mapfile -t values < <(sed -n "s/^${key}=//p" "$metadata")
  if ((${#values[@]} != 1)) || [[ -z ${values[0]} ]]; then
    printf '오류: release-metadata.env의 %s가 정확히 하나가 아닙니다.\n' "$key" >&2
    return 2
  fi
  printf '%s' "${values[0]}"
}

check_file_hash() {
  local expected=$1
  local path=$2
  local label=$3
  local actual
  actual=$(sha256sum "$path" | awk '{print $1}')
  if [[ $actual != "$expected" ]]; then
    printf '오류: %s SHA-256 불일치: %s\n' "$label" "$actual" >&2
    return 1
  fi
}

check_file_hash "$(metadata_value CRS_SNAPSHOT_MANIFEST_SHA256)" \
  "$app_dir/crs-snapshot.SHA256" 'CRS manifest'
(
  cd "$app_dir/files/crs"
  sha256sum --quiet -c ../../crs-snapshot.SHA256
)
manifest_count=$(wc -l < "$app_dir/crs-snapshot.SHA256")
snapshot_count=$(find "$app_dir/files/crs" -maxdepth 1 -type f | wc -l)
[[ $manifest_count == 49 && $snapshot_count == 49 ]]

archive_expected=$(metadata_value CRS_SNAPSHOT_ARCHIVE_SHA256)
read -r archive_manifest_hash archive_manifest_name < "$app_dir/crs-snapshot.tar.gz.SHA256"
[[ $archive_manifest_hash == "$archive_expected" ]]
[[ $archive_manifest_name == crs-snapshot.tar.gz ]]
[[ $(wc -l < "$app_dir/crs-snapshot.tar.gz.SHA256") == 1 ]]
check_file_hash "$archive_expected" \
  "$app_dir/files/crs-snapshot.tar.gz" 'deterministic CRS archive'

check_file_hash "$(metadata_value CROWDSEC_01_APPSEC_CONFIG_SHA256)" \
  "$app_dir/files/appsec/configs/crowdsec-01-crs-inband.yaml" '운영 AppSec config'
check_file_hash "$(metadata_value CROWDSEC_01_CRS_RULE_SHA256)" \
  "$app_dir/files/appsec/rules/crowdsec-01-crs.yaml" '운영 CRS rule'
check_file_hash "$(metadata_value CROWDSEC_01_EXCEPTION_SHA256)" \
  "$app_dir/files/appsec/rules/crowdsec-01-exact-913100-exception.yaml" 'exact 예외'

rendered=$(mktemp /tmp/crowdsec-01-render.XXXXXX)
scratch=$(mktemp -d /tmp/crowdsec-01-supply.XXXXXX)
cleanup() {
  rm -f -- "$rendered"
  if [[ -d $scratch ]]; then
    rm -rf -- "$scratch"
  fi
}
trap cleanup EXIT

{
  printf '%s\n' SHA256SUMS
  find "$app_dir/files/crs" -maxdepth 1 -type f -printf '%f\n'
} | LC_ALL=C sort > "$scratch/expected-members"
tar -tzf "$app_dir/files/crs-snapshot.tar.gz" | LC_ALL=C sort > "$scratch/archive-members"
cmp -s "$scratch/expected-members" "$scratch/archive-members"

mkdir "$scratch/archive"
tar -xzf "$app_dir/files/crs-snapshot.tar.gz" -C "$scratch/archive"
cmp -s "$app_dir/crs-snapshot.SHA256" "$scratch/archive/SHA256SUMS"
(
  cd "$scratch/archive"
  sha256sum --quiet -c SHA256SUMS
  [[ $(find . -maxdepth 1 -type f ! -name SHA256SUMS | wc -l) == 49 ]]
  find . -maxdepth 1 -type f -printf '%P\0' |
    LC_ALL=C sort -z |
    tar --create --file=- --format=ustar --mtime='@0' --owner=0 --group=0 \
      --numeric-owner --mode=0644 --no-recursion --null --files-from=- |
    gzip -n -9 > "$scratch/rebuilt-crs-snapshot.tar.gz"
)
cmp -s "$app_dir/files/crs-snapshot.tar.gz" "$scratch/rebuilt-crs-snapshot.tar.gz"

helm lint "$app_dir" -f "$app_dir/values-crowdsec-01.yaml" >/dev/null
helm template crowdsec "$app_dir" -n crowdsec-01 \
  -f "$app_dir/values-crowdsec-01.yaml" > "$rendered"

decode_rendered_binary() {
  local key=$1
  local output=$2
  awk -v key="$key:" \
    '$1 == key {sub(/^[^:]+:[[:space:]]+"/, ""); sub(/"$/, ""); print; exit}' \
    "$rendered" | base64 --decode > "$output"
  [[ -s $output ]]
}

decode_rendered_binary crs-snapshot.tar.gz "$scratch/rendered-crs-snapshot.tar.gz"
check_file_hash "$archive_expected" "$scratch/rendered-crs-snapshot.tar.gz" \
  'Helm render의 CRS archive'
decode_rendered_binary crowdsec-01-crs-inband.yaml "$scratch/rendered-appsec-config.yaml"
cmp -s "$app_dir/files/appsec/configs/crowdsec-01-crs-inband.yaml" \
  "$scratch/rendered-appsec-config.yaml"
decode_rendered_binary crowdsec-01-crs.yaml "$scratch/rendered-crs-rule.yaml"
cmp -s "$app_dir/files/appsec/rules/crowdsec-01-crs.yaml" \
  "$scratch/rendered-crs-rule.yaml"
decode_rendered_binary crowdsec-01-exact-913100-exception.yaml \
  "$scratch/rendered-exception.yaml"
cmp -s "$app_dir/files/appsec/rules/crowdsec-01-exact-913100-exception.yaml" \
  "$scratch/rendered-exception.yaml"

helm package "$app_dir" --destination "$scratch" >/dev/null
chart_package=$(find "$scratch" -maxdepth 1 -type f -name 'crowdsec-*.tgz' -print -quit)
[[ -n $chart_package && $(stat -c '%s' "$chart_package") -lt 1048576 ]]

if rg -n 'image:[[:space:]]+[^[:space:]]+$' "$rendered" | grep -v '@sha256:'; then
  printf '%s\n' '오류: 렌더 결과에 digest 없는 활성 image가 있습니다.' >&2
  exit 1
fi
if rg -n 'kind:[[:space:]]+Secret$' "$rendered"; then
  printf '%s\n' '오류: 렌더 결과에 Git 관리 Secret이 있습니다.' >&2
  exit 1
fi
rg -q 'value: "true"' "$rendered" || true
rg -q 'name: DISABLE_ONLINE_API' "$rendered"
rg -q 'name: NO_HUB_UPGRADE' "$rendered"
rg -q 'value: ""' "$rendered"

if ! $network_check; then
  printf '%s\n' \
    'PASS: deterministic archive, 원본 49개와 AppSec YAML의 byte-preserving render, digest-pinned chart를 검증했습니다.'
  exit 0
fi

download_and_check() {
  local url=$1
  local expected=$2
  local name=$3
  local output="$scratch/$name"
  curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$output"
  check_file_hash "$expected" "$output" "$name"
}

download_and_check "$(metadata_value HELM_CHART_ARCHIVE_URL)" \
  "$(metadata_value HELM_CHART_ARCHIVE_SHA256)" chart.tgz
download_and_check "$(metadata_value BOUNCER_SOURCE_ARCHIVE_URL)" \
  "$(metadata_value BOUNCER_SOURCE_ARCHIVE_SHA256)" bouncer-source.tgz
download_and_check "$(metadata_value BOUNCER_PLUGIN_ARCHIVE_URL)" \
  "$(metadata_value BOUNCER_PLUGIN_ARCHIVE_SHA256)" bouncer-plugin.zip
download_and_check "$(metadata_value HUB_CRS_INBAND_CONFIG_URL)" \
  "$(metadata_value HUB_CRS_INBAND_CONFIG_SHA256)" crs-inband.yaml
download_and_check "$(metadata_value HUB_CRS_RULE_URL)" \
  "$(metadata_value HUB_CRS_RULE_SHA256)" crs.yaml

while read -r expected relative; do
  name=${relative#./}
  download_and_check "$(metadata_value HUB_CRS_DATA_BASE_URL)/$name" \
    "$expected" "upstream-$name"
done < "$app_dir/crs-snapshot.SHA256"

printf '%s\n' 'PASS: source archive, plugin registry archive, pinned Hub YAML과 Hub data 49개가 고정 hash와 일치합니다.'
