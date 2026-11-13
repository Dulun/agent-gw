#!/usr/bin/env bash
# agent-vm transparent proxy + fail-closed killswitch (single-NIC, always on, no toggle).
# LAN_IF is virbr0; never touches the main table, only writes table 200 + nft tables agentvm/agentvm_guard.
# Missing tun-gw means no network, never a direct leak.
#
#   sudo ./agent-vm-route.sh up       # guard + route (idempotent)
#   sudo ./agent-vm-route.sh guard    # killswitch only (no tun-gw needed, runs earliest at boot)
#   sudo ./agent-vm-route.sh route    # table 200 only (needs tun-gw)
#   sudo ./agent-vm-route.sh unguard|unroute|down|status
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# systemd units carry no EnvironmentFile; load the repo's own config so VM_MAC/HOME_IF exist at boot.
for f in "$ROOT/.env" "$ROOT/vm.env"; do
  [ -f "$f" ] && { set -a; . "$f"; set +a; }
done

VM_IP="${VM_IP:-192.168.122.200}"
VM_MAC="${VM_MAC:-}"
LAN_IF="${LAN_IF:-virbr0}"
TUN_DEV="${TUN_DEV:-tun-gw}"
TABLE="${TABLE:-200}"
PRIO="${PRIO:-5200}"
DNS_TARGET="${DNS_TARGET:-192.168.122.1:1053}"
DNS_PORT="${DNS_PORT:-1053}"
CTRL_PORT="${CTRL_PORT:-11098}"
# host-side caches (cache/compose.yaml): apt, npm, docker hub, docker mcr
CACHE_PORTS="${CACHE_PORTS:-3142,4873,5000,5001}"
VM_NAME="${VM_NAME:-agent-vm-xlarge}"
HOME_IF="${HOME_IF:-wlp6s0}"
SSH_PORT="${SSH_PORT:-2222}"
NFT_TABLE='agentvm'
NFT_GUARD='agentvm_guard'

need_root() { [[ "${EUID}" -eq 0 ]] || { echo 'need root: sudo' >&2; exit 1; }; }

guard() {
  need_root
  [[ -n "$VM_MAC" ]] || { echo 'VM_MAC is empty' >&2; exit 1; }
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true
  nft add table ip "$NFT_TABLE"
  nft add chain ip "$NFT_TABLE" dns '{ type nat hook prerouting priority dstnat - 5; policy accept; }'
  nft add rule ip "$NFT_TABLE" dns ip saddr "$VM_IP" udp dport 53 dnat ip to "$DNS_TARGET"
  nft add rule ip "$NFT_TABLE" dns ip saddr "$VM_IP" tcp dport 53 dnat ip to "$DNS_TARGET"
  # host SSH_PORT -> guest 22 (lets other LAN devices reach the VM)
  nft add rule ip "$NFT_TABLE" dns tcp dport "$SSH_PORT" dnat ip to "$VM_IP:22"
  if ! iptables -C FORWARD -d "$VM_IP"/32 -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -d "$VM_IP"/32 -p tcp --dport 22 -j ACCEPT
  fi
  nft delete table inet "$NFT_GUARD" 2>/dev/null || true
  nft add table inet "$NFT_GUARD"
  # forward: the guest may leave only through tun-gw, never over IPv6, never directly.
  nft add chain inet "$NFT_GUARD" egress '{ type filter hook forward priority filter + 10; policy accept; }'
  nft add rule inet "$NFT_GUARD" egress meta nfproto ipv6 counter drop
  # No UDP from the guest: that is WebRTC (STUN/TURN), QUIC, mDNS, NTP. HTTPS falls back to TCP.
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" meta l4proto udp counter drop
  # Global mode ignores the proxy's private-IP rejects, so the RFC1918/metadata block lives here.
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" ip daddr '{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8 }' counter drop
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" oifname "$TUN_DEV" counter accept
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" counter drop
  # input: host -> guest stays possible (output hook), guest -> host does not, except the DNS
  # proxy that the dnat rule above rewrites to this host:DNS_PORT.
  nft add chain inet "$NFT_GUARD" ingress '{ type filter hook input priority filter + 10; policy accept; }'
  nft add rule inet "$NFT_GUARD" ingress iifname "$LAN_IF" meta nfproto ipv6 counter drop
  nft add rule inet "$NFT_GUARD" ingress iifname "$LAN_IF" ether saddr "$VM_MAC" ct state established,related counter accept
  nft add rule inet "$NFT_GUARD" ingress iifname "$LAN_IF" ether saddr "$VM_MAC" udp dport "$DNS_PORT" counter accept
  nft add rule inet "$NFT_GUARD" ingress iifname "$LAN_IF" ether saddr "$VM_MAC" tcp dport "$DNS_PORT" counter accept
  # host-side package/registry caches: the guest's only other way to reach this host
  nft add rule inet "$NFT_GUARD" ingress iifname "$LAN_IF" ether saddr "$VM_MAC" tcp dport "{ $CACHE_PORTS }" counter accept
  nft add rule inet "$NFT_GUARD" ingress iifname "$LAN_IF" ether saddr "$VM_MAC" counter drop
  # The proxy controller is the one place that can make DIRECT reachable again. The guest is
  # already firewalled off it; this also keeps local non-root users off it (the panel runs as root).
  nft add chain inet "$NFT_GUARD" api '{ type filter hook output priority filter + 10; policy accept; }'
  nft add rule inet "$NFT_GUARD" api tcp dport "$CTRL_PORT" meta skuid != 0 counter drop
  persist_lock
}

# A second, identical guard owned by /etc/nftables.conf and loaded by nftables.service at boot.
# Nothing in this repo deletes it, so stopping/failing our units, flushing the dynamic table, or
# a broken reboot still cannot let the guest out. Editing /etc/nftables.conf is the only way.
persist_lock() {
  local conf=/etc/nftables.conf mac="$VM_MAC"
  [ -n "$mac" ] || mac='00:00:00:00:00:00'
  cat >"$conf" <<EOF
#!/usr/sbin/nft -f
# Managed by agent-gw: permanent fail-closed egress guard for ${VM_IP}.
# No flush ruleset: other subsystems (docker, libvirt) own their own tables.
# add+delete makes reloading this file idempotent instead of stacking duplicate rules.
add table inet agentvm_lock
delete table inet agentvm_lock
table inet agentvm_lock {
  chain egress {
    type filter hook forward priority filter + 5; policy accept;
    meta nfproto ipv6 counter drop
    ether saddr ${mac} meta l4proto udp counter drop
    ether saddr ${mac} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8 } counter drop
    ether saddr ${mac} oifname "${TUN_DEV}" accept
    ether saddr ${mac} counter drop
    iifname "${LAN_IF}" counter drop
  }
  chain api {
    type filter hook output priority filter + 5; policy accept;
    tcp dport ${CTRL_PORT} meta skuid != 0 counter drop
  }
  chain ingress {
    type filter hook input priority filter + 5; policy accept;
    iifname "${LAN_IF}" meta nfproto ipv6 counter drop
    iifname "${LAN_IF}" ether saddr ${mac} ct state established,related accept
    iifname "${LAN_IF}" ether saddr ${mac} udp dport ${DNS_PORT} accept
    iifname "${LAN_IF}" ether saddr ${mac} tcp dport ${DNS_PORT} accept
    iifname "${LAN_IF}" ether saddr ${mac} tcp dport { ${CACHE_PORTS} } accept
    iifname "${LAN_IF}" ether saddr ${mac} counter drop
  }
}
EOF
  nft -f "$conf" 2>/dev/null || { echo "persist_lock: nft -f failed" >&2; return 0; }
  systemctl enable --now nftables.service >/dev/null 2>&1 || true
}


route() {
  need_root
  ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "missing ${TUN_DEV}: start agent-gw-core first" >&2; exit 1; }
  ip route replace 192.168.122.0/24 dev "$LAN_IF" table "$TABLE"
  ip route replace default dev "$TUN_DEV" table "$TABLE"
  ip rule del from "$VM_IP" table "$TABLE" 2>/dev/null || true
  ip rule add from "$VM_IP" table "$TABLE" priority "$PRIO"
  pin_nodes
}

# Keep the gateway's own dial to the node server out of the host's desktop TUN.
# Without this, a host TUN with auto-route swallows that dial and the VM's egress
# silently depends on whatever node the desktop is using (and dies with it).
pin_nodes() {
  need_root
  local cfg gw ips ip
  cfg="${CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gw-data/config.yaml}"
  [ -f "$cfg" ] || { echo "pin_nodes: no $cfg" >&2; return 0; }
  gw="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
  [ -n "$gw" ] || { echo "pin_nodes: no default gateway" >&2; return 0; }
  ips="$(python3 - "$cfg" <<'EOF'
import socket, sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
seen = set()
for p in d.get('proxies') or []:
    s = str((p or {}).get('server') or '').strip()
    if not s:
        continue
    try:
        socket.inet_aton(s)
        seen.add(s)
    except OSError:
        try:
            for _, _, _, _, sa in socket.getaddrinfo(s, None, socket.AF_INET):
                seen.add(sa[0])
        except OSError:
            pass
print('\n'.join(sorted(seen)))
EOF
)"
  while read -r ip; do
    [ -n "$ip" ] && ip route replace "$ip/32" via "$gw" dev "$HOME_IF"
  done <<< "$ips"
  echo "pinned node routes via ${HOME_IF} (gw ${gw})"
}


unguard() {
  need_root
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true
  nft delete table inet "$NFT_GUARD" 2>/dev/null || true
  iptables -D FORWARD -d "$VM_IP"/32 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
}

unroute() {
  need_root
  ip rule del from "$VM_IP" table "$TABLE" 2>/dev/null || true
  ip route flush table "$TABLE" 2>/dev/null || true
}

# Only for manual use: each systemd unit tears down just its own half, so restarting
# one never silently removes the killswitch or the policy route belonging to the other.
down() {
  unguard
  unroute
  status
}

# Keep the guest wall clock on the host clock (qemu-guest-agent), so the LA timezone in the
# guest shows the node's local time without an NTP path that could leak.
clock() {
  need_root
  virsh domtime "$VM_NAME" --sync >/dev/null
}

status() {
  echo "--- ip rule (${VM_IP} -> table ${TABLE}) ---"
  ip rule show | grep -F "from ${VM_IP}" || echo '(not installed)'
  echo "--- table ${TABLE} ---"
  ip route show table "$TABLE" 2>&1 || true
  echo "--- nft ${NFT_TABLE} ---"
  nft list table ip "$NFT_TABLE" 2>/dev/null || echo '(not installed)'
  echo "--- nft ${NFT_GUARD} (by MAC ${VM_MAC}) ---"
  nft list table inet "$NFT_GUARD" 2>/dev/null || echo '(not installed)'
}

case "${1:-up}" in
  up) guard; route; status ;;
  guard) guard; status ;;
  route) route; status ;;
  unguard) unguard; status ;;
  unroute) unroute; status ;;
  down) down ;;
  clock) clock ;;
  status) status ;;
  *) echo "usage: $0 {up|guard|route|unguard|unroute|down|clock|status}" >&2; exit 2 ;;
esac
