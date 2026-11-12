#!/bin/sh
# Single-NIC gateway entrypoint: only runs mihomo + table-200 default-route watchdog.
# killswitch lives on the host in agent-vm-route.sh guard (nft, matched by VM MAC, always on).
# LAN = virbr0 (existing libvirt bridge; physical NIC untouched, no DHCP here, libvirt owns it).
set -e

TUN_DEV="${TUN_DEV:-tun-gw}"
TABLE="${TABLE:-200}"
BRIDGE="${BRIDGE:-virbr0}"
HOME_IF="${HOME_IF:-wlp6s0}"

echo "[agent-gw] starting mihomo..."
/usr/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml &
MIHOMO_PID=$!
echo "[agent-gw] mihomo started (PID: ${MIHOMO_PID})"

echo "[agent-gw] waiting for ${TUN_DEV}..."
attempts=0
while [ "$attempts" -lt 30 ]; do
  if ip link show "${TUN_DEV}" >/dev/null 2>&1; then
    echo "[agent-gw] ${TUN_DEV} is UP!"
    break
  fi
  attempts=$((attempts + 1))
  sleep 0.5
done

# Table-200 default route points at TUN; mihomo hot-reload recreates tun and drops the route, watchdog restores it.
(
  while true; do
    if ip link show "${TUN_DEV}" >/dev/null 2>&1; then
      if ! ip route show table "${TABLE}" | grep -q "${TUN_DEV}"; then
        ip route replace 192.168.122.0/24 dev "${BRIDGE}" table "${TABLE}" 2>/dev/null || true
        ip route replace default dev "${TUN_DEV}" table "${TABLE}" 2>/dev/null || true
      fi
    fi
    sleep 2
  done
) &

# Fail-closed watchdog: mihomo can be switched to global via its API, and in global mode the
# FORWARD-only nft guard never sees its host-originated dials (PITFALLS 1). Force the two
# settings that make DIRECT unreachable back to their safe values every 10s.
(
  while true; do
    python3 - <<'PY' 2>/dev/null
import json, os, urllib.request
api = "http://127.0.0.1:%s" % os.environ.get("CTRL_PORT", "11098")
hdr = {"Authorization": "Bearer " + os.environ.get("API_SECRET", ""),
       "Content-Type": "application/json"}
def call(path, method="GET", body=None):
    r = urllib.request.Request(api + path, method=method, headers=hdr,
                               data=json.dumps(body).encode() if body else None)
    return json.loads(urllib.request.urlopen(r, timeout=3).read().decode() or "{}")
try:
    mode = call("/configs").get("mode")
    if mode != "global":
        call("/configs", "PATCH", {"mode": "global"})
        print("[agent-gw] watchdog: mode %r -> global" % mode, flush=True)
    proxies = (call("/proxies") or {}).get("proxies") or {}
    g = proxies.get("GLOBAL") or {}
    if g and g.get("now") != "EXIT":
        call("/proxies/GLOBAL", "PUT", {"name": "EXIT"})
        print("[agent-gw] watchdog: GLOBAL %r -> EXIT" % g.get("now"), flush=True)
    if (proxies.get("EXIT") or {}).get("now") == "DIRECT":
        print("[agent-gw] watchdog: EXIT is DIRECT, no safe node", flush=True)
except Exception:
    pass
PY
    sleep 10
  done
) &

# Node server-IP sidecar: panel reads it read-only
python3 -c 'import yaml;d=yaml.safe_load(open("/etc/mihomo/config.yaml",encoding="utf-8"));open("/etc/mihomo/node-server-ip.env","w",encoding="utf-8").write("".join(p["name"]+"="+str(p.get("server",""))+"\n" for p in d.get("proxies",[])))' 2>/dev/null || true

echo "[agent-gw] route watchdog running."
trap 'kill -TERM "$MIHOMO_PID" 2>/dev/null; exit 0' TERM INT
wait "$MIHOMO_PID"
