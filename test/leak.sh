#!/usr/bin/env bash
# Adversarial leak hunt inside the guest: every way a program can learn or use its real IP.
# The guest may only ever see the node's egress IP, a fake-ip from the gateway resolver, or
# nothing. Any other public IP, the home IP, or a reachable host/LAN/metadata service fails.
# Note: mihomo's TUN completes TCP handshakes before rejecting, so every reachability probe
# asks for real payload ("did any data flow"), never just connect().
# Usage: test/leak.sh [rounds]   (default 3)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
for f in .env vm.env; do [ -f "$f" ] && { set -a; . "$f"; set +a; }; done

ROUNDS="${1:-3}"
GUEST="${VM_IP:-192.168.122.200}"
HOME_IF="${HOME_IF:-wlp6s0}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
NODE="$(python3 -c 'import sys,yaml;d=yaml.safe_load(open(sys.argv[1]));print((d.get("proxies") or [{}])[0].get("server",""))' gw-data/config.yaml)"
HOME_IP="$(curl -s -m 5 --interface "$HOME_IF" https://ipinfo.io/ip 2>/dev/null)"
FAKE_CIDR="${FAKE_IP_RANGE:-198.20.0.0/16}"
echo "node=$NODE home=$HOME_IP guest=$GUEST fake=$FAKE_CIDR rounds=$ROUNDS"
[ -n "$NODE" ] || { echo "cannot determine node"; exit 2; }

fail=0
check() { # name want actual
  local v=PASS
  [ "$3" = "$2" ] || { v=FAIL; fail=$((fail+1)); }
  printf '%-42s want=%-6s got=%-26s %s\n' "$1" "$2" "$3" "$v"
}
check_safe() { # name actual: node or blocked both fine, anything else is a leak
  local v=PASS
  case "$2" in NODE|BLOCKED|FAKEIP|NODE-EGRESS) ;; *) v=FAIL; fail=$((fail+1)) ;; esac
  printf '%-42s want=%-6s got=%-26s %s\n' "$1" "SAFE" "$2" "$v"
}
# classify an observed public IP
vip() {
  case "$1" in
    "") echo BLOCKED ;;
    "$NODE") echo NODE ;;
    "$HOME_IP") echo LEAK ;;
    *) echo "LEAK($1)" ;;
  esac
}
is_fake() { python3 - "$1" "$FAKE_CIDR" <<'PY'
import ipaddress, sys
try:
    print("FAKEIP" if ipaddress.ip_address(sys.argv[1].strip()) in ipaddress.ip_network(sys.argv[2]) else "real")
except Exception:
    print("real")
PY
}

GUEST_SCRIPT="$(cat test/guest-probe.sh)"

for round in $(seq 1 "$ROUNDS"); do
  echo "## round $round/$ROUNDS ($(date +%H:%M:%S))"
  out=$(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=6 "root@$GUEST" 'bash -s' <<<"$GUEST_SCRIPT" 2>/dev/null)
  [ -n "$out" ] || { echo "  guest unreachable"; fail=$((fail+1)); continue; }
  v() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

  for k in IP_IPINFO IP_IFCONFIG IP_ICANHAZ IP_IPIFY; do check "$k" NODE "$(vip "$(v "$k")")"; done
  check_safe "IP_IPAPI (plain http)" "$(vip "$(v IP_IPAPI)")"
  check "IPv6 request" BLOCKED "$( [ -z "$(v V6)" ] && echo BLOCKED || echo "LEAK($(v V6))")"
  check_safe "DoH lookup -> egress" "$(vip "$(v DOH_EGRESS)")"
  check "DoT lookup -> egress" NODE "$(vip "$(v DOT_EGRESS)")"
  ak=$(v AKAMAI); [ -n "$ak" ] && [ "$(is_fake "$ak")" = FAKEIP ] && ak="(fake-ip $ak)"
  case "$ak" in ""|"(fake-ip "*) check_safe "resolver identity" FAKEIP ;; *) check_safe "resolver identity" "$(vip "$ak")" ;; esac
  check "STUN udp/19302" BLOCKED "$(v STUN_UDP)"
  check "STUN tcp/3478" BLOCKED "$(v STUN_TCP)"
  check "host sshd"      BLOCKED "$(v HOST_SSH)"
  check "host panel"     BLOCKED "$(v HOST_PANEL)"
  check "host mihomo"    BLOCKED "$(v HOST_MIHOMO)"
  check "host controller" BLOCKED "$(v HOST_CTRL)"
  check "host dns proxy" OPEN "$(v HOST_DNS)"
  check "home gateway"   BLOCKED "$(v LAN_GW)"
  check "home peer"      BLOCKED "$(v LAN_PEER)"
  check "metadata 169.254.169.254" BLOCKED "$(v META)"
  check "other guest"    BLOCKED "$(v OTHER_VM)"
  check "public https"   "200" "$(v PUB_HTTP)"
  check "ntp udp/123"    BLOCKED "$(v NTP)"
done

echo
if [ "$fail" -eq 0 ]; then echo "RESULT: no leak found in $ROUNDS round(s)"; else echo "RESULT: $fail leak(s)/failure(s)"; fi
exit $(( fail > 0 ))
