#!/usr/bin/env bash
# agent-vm transparent proxy + fail-closed killswitch (single-NIC, always on, no toggle).
# LAN_IF is virbr0; never touches the main table, only writes table 200 + nft tables agentvm/agentvm_guard.
# Missing tun-gw means no network, never a direct leak.
#
#   sudo ./agent-vm-route.sh up       # guard + route (idempotent)
#   sudo ./agent-vm-route.sh guard    # killswitch only (no tun-gw needed, runs earliest at boot)
#   sudo ./agent-vm-route.sh route    # table 200 only (needs tun-gw)
#   sudo ./agent-vm-route.sh down|status
set -Eeuo pipefail

VM_IP="${VM_IP:-192.168.122.200}"
VM_MAC="${VM_MAC:-}"
LAN_IF="${LAN_IF:-virbr0}"
TUN_DEV="${TUN_DEV:-tun-gw}"
TABLE="${TABLE:-200}"
PRIO="${PRIO:-5200}"
DNS_TARGET="${DNS_TARGET:-192.168.122.1:1053}"
HOME_CIDR="${HOME_CIDR:-192.168.0.0/24}"
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
  nft add chain inet "$NFT_GUARD" egress '{ type filter hook forward priority filter + 10; policy accept; }'
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" oifname "$TUN_DEV" counter accept
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" oifname "$LAN_IF" counter accept
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" ip daddr "$HOME_CIDR" counter accept
  nft add rule inet "$NFT_GUARD" egress ether saddr "$VM_MAC" counter drop
}

route() {
  need_root
  ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "missing ${TUN_DEV}: start agent-gw-core first" >&2; exit 1; }
  ip route replace 192.168.122.0/24 dev "$LAN_IF" table "$TABLE"
  ip route replace "$HOME_CIDR" dev "$HOME_IF" table "$TABLE"
  ip route replace default dev "$TUN_DEV" table "$TABLE"
  ip rule del from "$VM_IP" table "$TABLE" 2>/dev/null || true
  ip rule add from "$VM_IP" table "$TABLE" priority "$PRIO"
}

down() {
  need_root
  ip rule del from "$VM_IP" table "$TABLE" 2>/dev/null || true
  ip route flush table "$TABLE" 2>/dev/null || true
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true
  nft delete table inet "$NFT_GUARD" 2>/dev/null || true
  iptables -D FORWARD -d "$VM_IP"/32 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
  status
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
  down) down ;;
  status) status ;;
  *) echo "usage: $0 {up|guard|route|down|status}" >&2; exit 2 ;;
esac
