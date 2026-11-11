#!/usr/bin/env bash
# Scenario matrix: the guest must never exit via the home IP, in any state.
# Usage: test/matrix.sh   (needs sudo inside for nft/systemctl/ip; do not run the whole script as root)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
for f in .env vm.env; do [ -f "$f" ] && { set -a; . "$f"; set +a; }; done

NODE="${NODE_IP:-$(python3 -c 'import sys,yaml;d=yaml.safe_load(open(sys.argv[1]));print((d.get("proxies") or [{}])[0].get("server",""))' gw-data/config.yaml)}"
HOME_IF="${HOME_IF:-wlp6s0}"
HOME_IP="${HOME_IP:-$(curl -s -m 5 --interface "$HOME_IF" https://ipinfo.io/ip 2>/dev/null)}"
GUEST="${VM_IP:-192.168.122.200}"
# needs sudo for nft/systemctl, but ssh keys live in the invoking user's home
if [ "$(id -u)" = 0 ]; then USER_HOME="$(getent passwd "${SUDO_USER:-tony}" | cut -d: -f6)"; else USER_HOME="$HOME"; fi
SSH_KEY="${SSH_KEY:-$USER_HOME/.ssh/id_ed25519}"
# HOME_IP may be unresolvable while the host TUN is on; it only labels a leak, and any
# unexpected real IP still fails the check.
[ -n "$NODE" ] || { echo "cannot determine NODE"; exit 2; }
echo "node=$NODE home=$HOME_IP guest=$GUEST"
fail=0

probe() {
  local out rc ip
  out=$(ssh -i "$SSH_KEY" -o ConnectTimeout=6 -o BatchMode=yes "root@$GUEST" \
        'curl -s -m 8 https://ipinfo.io/ip 2>/dev/null; echo " rc=$?"' 2>/dev/null)
  rc=$(printf '%s' "$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')
  ip=$(printf '%s' "$out" | sed -n 's/^\([0-9.]*\).*/\1/p')
  if [ "${rc:-1}" != "0" ] || [ -z "$ip" ]; then echo BLOCKED
  elif [ "$ip" = "$NODE" ]; then echo NODE
  elif [ "$ip" = "$HOME_IP" ]; then echo HOME
  else echo "OTHER($ip)"; fi
}

safe() { # never HOME, never another real IP
  case "$1" in NODE|BLOCKED) return 0 ;; *) return 1 ;; esac
}

ok() { # want actual
  if [ "$1" = SAFE ]; then safe "$2"; else [ "$2" = "$1" ]; fi
}

# Poll until the guest reports `want` twice, 3s apart. Prevents counting a container
# that is still booting as a pass or a failure.
wait_for() {
  local want="$1" got
  for _ in $(seq 1 10); do
    got="$(probe)"
    if ok "$want" "$got"; then
      sleep 3
      got="$(probe)"
      ok "$want" "$got" && { echo "$got"; return; }
    fi
    sleep 3
  done
  probe
}

check() { # name allowed(SAFE|NODE|BLOCKED) actual
  local verdict=FAIL
  if [ "$2" = SAFE ]; then safe "$3" && verdict=PASS
  else [ "$3" = "$2" ] && verdict=PASS; fi
  [ "$verdict" = FAIL ] && fail=$((fail+1))
  printf '%-54s want=%-8s got=%-12s %s\n' "$1" "$2" "$3" "$verdict"
}

cleanup() {
  sudo ip route del blackhole "$NODE/32" >/dev/null 2>&1
  sudo systemctl start agent-vm-guard.service agent-vm-route.service >/dev/null 2>&1
  docker start agent-gw-core >/dev/null 2>&1
}
trap cleanup EXIT

# mihomo comes back before it can dial the node (hysteria2 handshake takes up to a minute);
# a probe that races it reports BLOCKED for a healthy stack.
wait_core() {
  local got
  for _ in $(seq 1 30); do
    got="$(curl -s -m 5 -x "http://127.0.0.1:${MIXED_PORT:-11095}" https://ipinfo.io/ip 2>/dev/null)"
    [ "$got" = "$NODE" ] && { echo "$got"; return 0; }
    sleep 5
  done
  echo "core-not-ready($got)"
  return 1
}

restore() {
  sudo systemctl start agent-vm-guard.service agent-vm-route.service >/dev/null 2>&1
  docker start agent-gw-core >/dev/null 2>&1
  wait_core >/dev/null || true
}

echo "## S1 baseline (everything up)"
wait_core >/dev/null || true
check "core + guard + route up" NODE "$(wait_for NODE)"

echo "## S2 gateway container down"
docker stop agent-gw-core >/dev/null 2>&1; sleep 2
check "core stopped" BLOCKED "$(wait_for BLOCKED)"
docker start agent-gw-core >/dev/null 2>&1; sleep 8

echo "## S3 policy route removed (route unit stopped)"
sudo systemctl stop agent-vm-route.service >/dev/null 2>&1; sleep 1
check "table 200 gone" BLOCKED "$(wait_for BLOCKED)"
sudo systemctl start agent-vm-route.service >/dev/null 2>&1; sleep 2

echo "## S4 dynamic guard flushed by hand (route still intact)"
sudo nft delete table inet agentvm_guard >/dev/null 2>&1
check "agentvm_guard deleted" SAFE "$(wait_for SAFE)"
sudo systemctl restart agent-vm-guard.service >/dev/null 2>&1; sleep 2

echo "## S5 both units stopped (only the lock table protects)"
sudo systemctl stop agent-vm-route.service agent-vm-guard.service >/dev/null 2>&1; sleep 1
check "guard + route stopped" BLOCKED "$(wait_for BLOCKED)"

echo "## S6 reboot simulation: nftables.service reload, units still down"
sudo systemctl restart nftables.service >/dev/null 2>&1; sleep 1
check "lock table reloaded" BLOCKED "$(wait_for BLOCKED)"

echo "## S7 restore"
restore
check "restored" NODE "$(wait_for NODE)"

echo "## S8 node unreachable (blackhole + restart core so no session survives)"
sudo ip route replace blackhole "$NODE/32" || echo "  (blackhole failed!)"
docker restart agent-gw-core >/dev/null 2>&1; sleep 10
ip route show "$NODE/32" | grep -q blackhole || { echo "  blackhole not installed"; fail=$((fail+1)); }
check "node blackholed, fresh dial" BLOCKED "$(wait_for BLOCKED)"
sudo ip route del blackhole "$NODE/32" 2>/dev/null; sudo ip route replace "$NODE/32" via "$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')" dev "$HOME_IF" 2>/dev/null
sudo systemctl restart agent-vm-route.service >/dev/null 2>&1
docker restart agent-gw-core >/dev/null 2>&1; sleep 10
check "blackhole removed, egress back" NODE "$(wait_for NODE)"

echo "## S9 hardcoded public DNS inside the guest"
out=$(ssh -i "$SSH_KEY" -o ConnectTimeout=6 -o BatchMode=yes "root@$GUEST" \
      'command -v dig >/dev/null && dig +short +time=3 +tries=1 @8.8.8.8 ipinfo.io | head -n 1 || echo no-dig' 2>/dev/null)
echo "  dig @8.8.8.8 -> ${out:-none}"

echo "## S10 config assertion blocks a leaky config"
cp gw-data/config.yaml /tmp/cfg.bak
python3 - <<'EOF'
import yaml
p='gw-data/config.yaml'
d=yaml.safe_load(open(p))
d['mode']='global'
d['proxy-groups']=[g for g in d['proxy-groups'] if g['name']!='GLOBAL']
yaml.safe_dump(d,open(p,'w'),allow_unicode=True)
EOF
if python3 - gw-data/config.yaml <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
mode = d.get('mode', 'rule')
groups = {g.get('name'): g for g in d.get('proxy-groups') or []}
if mode == 'global' and 'GLOBAL' not in groups:
    sys.exit('leak: mode: global without a GLOBAL group falls back to DIRECT')
for g in groups.values():
    if 'DIRECT' in (g.get('proxies') or []):
        sys.exit(f"leak: proxy-group {g.get('name')} can select DIRECT")
EOF
then echo "  LEAK NOT DETECTED"; fail=$((fail+1)); else echo "  leaky config rejected: PASS"; fi
cp /tmp/cfg.bak gw-data/config.yaml

echo "## S11 guest IPv6 defaults"
ssh -i "$SSH_KEY" -o ConnectTimeout=6 -o BatchMode=yes "root@$GUEST" 'ip -6 route show default 2>/dev/null | head -n 2' 2>/dev/null | sed 's/^/  /'

echo
if [ "$fail" -eq 0 ]; then echo "RESULT: all scenarios passed"; else echo "RESULT: $fail scenario(s) FAILED"; fi
