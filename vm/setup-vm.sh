#!/usr/bin/env bash
# Create (or recreate) the agent-vm KVM guest. Idempotent: skips if the domain exists.
# Usage: vm/setup-vm.sh  (reads ../.env + vm.env, falls back to vm.env.example)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] || { cp .env.example .env; echo "created .env, edit VM_MAC/GOLDEN_IMAGE first"; exit 1; }
[ -f vm.env ] || cp vm/vm.env.example vm.env
set -a; . ./.env; set +a
set -a; . ./vm.env; set +a

: "${VM_NAME:?set VM_NAME in vm.env}"
: "${VM_MAC:?set VM_MAC in .env}"
: "${VM_IP:?set VM_IP in .env}"
GOLDEN_IMAGE="${GOLDEN_IMAGE:-}"
GOLDEN_IMAGE="${GOLDEN_IMAGE/#\~/$HOME}"
VM_POOL_DIR="${VM_POOL_DIR:-/var/lib/libvirt/images}"

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "$VM_NAME already exists, skip (virsh undefine $VM_NAME to rebuild)"
  exit 0
fi

# pool dir: overlay + seed
OVERLAY="$VM_POOL_DIR/${VM_NAME}.qcow2"
SEED="$VM_POOL_DIR/${VM_NAME}-seed.iso"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ssh keys (space-separated .pub list)
KEYS=""
for k in $SSH_PUBKEYS; do
  # shellcheck disable=SC2086
  f=$(eval echo "$k")
  [ -f "$f" ] || { echo "missing key: $f"; exit 1; }
  KEYS="$KEYS      $(cat "$f")"
done

# render cloud-init
sed -e "s|\${VM_NAME}|$VM_NAME|g" -e "s|\${VM_IP}|$VM_IP|g" vm/meta-data.template > "$TMP/meta-data"
python3 - "$TMP/user-data" vm/user-data.template.yaml "$KEYS" <<'EOF'
import sys
out, tpl = sys.argv[1], sys.argv[2]
keys = sys.argv[3].strip().split("      ")
keys = [k.strip() for k in keys if k.strip()]
t = open(tpl, encoding='utf-8').read()
t = t.replace('__SSH_KEYS__', '\n'.join('      ' + k for k in keys))
t = t.replace('${VM_NAME}', os.environ.get('VM_NAME', 'agent-vm-xlarge'))
t = t.replace('${VM_IP}', os.environ.get('VM_IP', '192.168.122.200'))
ts_host = os.environ.get('TS_HOSTNAME', '')
ts_key = os.environ.get('TS_AUTHKEY', '')
if ts_host and ts_key:
    join = f"  - [sh, -c, 'tailscale up --hostname={ts_host} --auth-key={ts_key} --ssh=false']"
elif ts_host:
    join = f"  # tailscale: installed; join manually once: tailscale up --hostname={ts_host}"
else:
    join = "  # tailscale: skipped (TS_HOSTNAME empty)"
t = t.replace('__TS_JOIN__', join)
open(out, 'w', encoding='utf-8').write(t)
print(f"{len(keys)} ssh keys")
EOF
cloud-localds "$TMP/seed.iso" "$TMP/user-data" "$TMP/meta-data"
sudo install -o libvirt-qemu -g kvm -m 0644 "$TMP/seed.iso" "$SEED"
sudo qemu-img create -f qcow2 -F qcow2 -b "$GOLDEN_IMAGE" "$OVERLAY" 60G >/dev/null
sudo chown libvirt-qemu:kvm "$OVERLAY"

# UEFI import (matches the golden image: OVMF + secure-boot)
sudo virt-install \
  --name "$VM_NAME" --memory "${VM_MEM_MB:-8192}" --vcpus "${VM_VCPUS:-8}" \
  --cpu host-passthrough --os-variant ubuntu24.04 --boot uefi \
  --disk "path=$OVERLAY,bus=virtio,discard=unmap" \
  --disk "path=$SEED,device=cdrom,bus=sata,readonly=on" \
  --network "network=default,mac=$VM_MAC,model=virtio" \
  --graphics none --console pty,target.type=serial \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --import --noautoconsole \
  --description "agent sandbox (agent-gw)"

# wait for the static IP, then clean cloud-init cache so SSH keys always land
for i in $(seq 1 24); do
  sleep 5
  if ping -c1 -W1 "$VM_IP" >/dev/null 2>&1; then break; fi
done
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$VM_IP" true 2>/dev/null \
  || echo "note: SSH not up yet (first boot takes ~1-2 min); retry: ssh root@$VM_IP"
echo "done: virsh list; ssh root@$VM_IP"
