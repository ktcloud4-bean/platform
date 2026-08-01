#!/usr/bin/env bash
# live packaged chart를 읽기만 하고 CROWDSEC-01 HelmChartConfig를 로컬에서 격리 렌더한다.
set -euo pipefail

: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

if (($# != 0)); then
  printf '%s\n' '사용법: verify-packaged-traefik-chart.sh' >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
readonly REPO_ROOT
metadata="$REPO_ROOT/gitops/apps/crowdsec/release-metadata.env"

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

chart_version=$(metadata_value TRAEFIK_PACKAGED_CHART_VERSION)
chart_sha=$(metadata_value TRAEFIK_PACKAGED_CHART_ARCHIVE_SHA256)
plugin_module=$(metadata_value BOUNCER_MODULE)
plugin_version=$(metadata_value BOUNCER_VERSION)
plugin_hash=$(metadata_value BOUNCER_PLUGIN_ARCHIVE_SHA256)
expected_chart="https://%{KUBERNETES_API}%/static/charts/traefik-${chart_version}.tgz"
chart_path="/var/lib/rancher/k3s/server/static/charts/traefik-${chart_version}.tgz"

if [[ ! $chart_version =~ ^[0-9A-Za-z.+-]+$ || ! $chart_sha =~ ^[0-9a-f]{64}$ ]]; then
  printf '%s\n' '오류: chart version 또는 SHA-256 형식이 올바르지 않습니다.' >&2
  exit 2
fi

ssh_base=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
  "$K3S_SSH_TARGET"
)

scratch=$(mktemp -d /tmp/crowdsec-01-traefik-chart.XXXXXX)
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

chart_json=$("${ssh_base[@]}" 'sudo -n /usr/local/bin/k3s kubectl -n kube-system get helmchart traefik -o json')
[[ $(jq -r '.spec.chart' <<< "$chart_json") == "$expected_chart" ]]
printf '%s' "$chart_json" | jq -r '.spec.valuesContent' > "$scratch/base-values.yaml"

"${ssh_base[@]}" "sudo -n cat $chart_path" > "$scratch/traefik.tgz"
[[ $(sha256sum "$scratch/traefik.tgz" | awk '{print $1}') == "$chart_sha" ]]

awk '/^  valuesContent: \|-/{capture=1; next} capture {sub(/^    /, ""); print}' \
  "$REPO_ROOT/gitops/apps/ingress/traefik-config.yaml" > "$scratch/hcc-values.yaml"
helm template traefik "$scratch/traefik.tgz" -n kube-system \
  -f "$scratch/base-values.yaml" -f "$scratch/hcc-values.yaml" \
  --set-string global.systemDefaultRegistry='' > "$scratch/rendered.yaml"

rg -Fq -- "--experimental.plugins.crowdsec.moduleName=$plugin_module" "$scratch/rendered.yaml"
rg -Fq -- "--experimental.plugins.crowdsec.version=$plugin_version" "$scratch/rendered.yaml"
rg -Fq -- "--experimental.plugins.crowdsec.hash=$plugin_hash" "$scratch/rendered.yaml"
rg -Fq 'image: rancher/mirrored-library-traefik:3.7.4' "$scratch/rendered.yaml"
rg -Fq 'mountPath: /plugins-storage' "$scratch/rendered.yaml"
rg -Fq 'mountPath: /run/secrets/crowdsec-01' "$scratch/rendered.yaml"
rg -Fq 'secretName: crowdsec-01-bouncer' "$scratch/rendered.yaml"
rg -Fq 'defaultMode: 288' "$scratch/rendered.yaml"

printf '%s\n' 'PASS: live packaged Traefik chart hash와 base values를 고정 HCC에 격리 렌더해 plugin args/storage/secret mount/image를 검증했습니다.'
