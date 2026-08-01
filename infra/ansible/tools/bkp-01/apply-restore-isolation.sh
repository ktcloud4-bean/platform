#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "사용법: $0 --controller-ip <IPv4> --expected-hostname <bkp01-restore-...>" >&2
  exit 2
}

controller_ip=""
expected_hostname=""
while (($#)); do
  case "$1" in
    --controller-ip)
      [[ $# -ge 2 ]] || usage
      controller_ip="$2"
      shift 2
      ;;
    --expected-hostname)
      [[ $# -ge 2 ]] || usage
      expected_hostname="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$controller_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || usage
[[ "$expected_hostname" =~ ^bkp01-restore-[a-z0-9-]+$ ]] || usage
[[ "$(hostname -s)" == "$expected_hostname" ]] || {
  echo "예상한 임시 restore hostname이 아닙니다" >&2
  exit 1
}
[[ -f /etc/bkp01-restore-drill.json ]] || {
  echo "BKP-01 restore sentinel이 없습니다" >&2
  exit 1
}
command -v nft >/dev/null || {
  echo "임시 restore VM에 nftables가 필요합니다" >&2
  exit 1
}

nft list table inet bkp01_isolation >/dev/null 2>&1 && nft delete table inet bkp01_isolation
nft -f - <<EOF
table inet bkp01_isolation {
  chain input {
    type filter hook input priority -500; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ip saddr ${controller_ip} tcp dport 22 ct state new accept
    counter drop comment "BKP-01 unmatched input"
  }
  chain output {
    type filter hook output priority -500; policy drop;
    oifname "lo" accept
    ip daddr ${controller_ip} tcp sport 22 accept
    ct state established,related accept
    counter drop comment "BKP-01 unmatched output"
  }
  chain forward {
    type filter hook forward priority -500; policy drop;
    counter drop comment "BKP-01 forwarded traffic"
  }
}
EOF

nft list table inet bkp01_isolation
