# agent-gw install/reinstall entry point: idempotent, safe to rerun.
# Generates secrets -> renders config -> starts containers -> installs killswitch.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f .env ] && [ ! -f vm.env ]; then cp .env.example .env; cp vm/vm.env.example vm.env; echo "created .env + vm.env, edit both first"; fi
[ -f .env ] || cp .env.example .env
[ -f vm.env ] || cp vm/vm.env.example vm.env
set -a; . ./.env; set +a
set -a; . ./vm.env 2>/dev/null || true; set +a

if [ -z "${API_SECRET:-}" ]; then
  API_SECRET="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  sed -i "s/^API_SECRET=.*/API_SECRET=$API_SECRET/" .env
  echo "generated API_SECRET"
fi
export API_SECRET

# Render mihomo config (envsubst-style: only ${VAR} replaced, mihomo syntax preserved)
render() { python3 - "$1" <<'EOF'
import os, re, sys
t = open(sys.argv[1], encoding='utf-8').read()
t = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}',
           lambda m: os.environ.get(m.group(1), m.group(2) or ''), t)
print(t, end='')
EOF
}
render gateway/config.example.yaml > gw-data/config.yaml

# Node source: provider URL or nodes.yaml file. EXIT group lists them, MATCH pins EXIT.
merge_nodes() { python3 - "$1" gw-data/config.yaml <<'EOF'
import os, sys, yaml
src = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
proxies = src.get('proxies') if isinstance(src, dict) else src
proxies = proxies if isinstance(proxies, list) else []
proxies = proxies or []
if not proxies:
    sys.exit('no proxies found')
names = [p['name'] for p in proxies if 'name' in p]
dst = yaml.safe_load(open(sys.argv[2], encoding='utf-8')) or {}
dst['proxies'] = proxies
want = os.environ.get('EXIT_NODE') or names[0]
dst['rules'] = [r for r in (dst.get('rules') or []) if not r.startswith('MATCH,')]
dst['rules'].append('MATCH,EXIT')
dst['proxy-groups'] = [{'name': 'EXIT', 'type': 'select', 'proxies': names}]
yaml.safe_dump(dst, open(sys.argv[2], 'w', encoding='utf-8'), allow_unicode=True)
print(f"merged {len(names)} proxies, exit default={want} (switch live in panel)")
EOF
}
if [ -n "${PROXY_PROVIDER_URL:-}" ]; then
  echo "fetching proxy-provider..."
  curl -fsSL --max-time 30 "$PROXY_PROVIDER_URL" -o /tmp/agw-providers.yaml
  merge_nodes /tmp/agw-providers.yaml
elif [ -f "${NODES_FILE:-nodes.yaml}" ]; then
  merge_nodes "${NODES_FILE:-nodes.yaml}"
fi

# Sidecar for the panel (read-only node server display)
python3 - gw-data/config.yaml <<'EOF' 2>/dev/null || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
with open('gw-data/node-server-ip.env', 'w', encoding='utf-8') as f:
    for p in d.get('proxies') or []:
        f.write(f"{p.get('name','')}={p.get('server','')}\n")
EOF

echo "--- vm ---"
./vm/setup-vm.sh
echo "--- gateway ---"

docker compose build
docker compose up -d --remove-orphans

# killswitch (host nft, always on)
sudo install -m 0644 agent-vm-guard.service agent-vm-route.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now agent-vm-guard.service
sudo env VM_IP="$VM_IP" VM_MAC="$VM_MAC" SSH_PORT="${SSH_PORT:-2222}" TABLE="${TABLE:-200}" \
  DNS_TARGET="192.168.122.1:${DNS_PORT:-1053}" HOME_CIDR="${HOME_CIDR:-192.168.0.0/24}" \
  HOME_IF="${HOME_IF:-wlp6s0}" ./agent-vm-route.sh guard
# route waits for tun-gw
sudo systemctl enable --now agent-vm-route.service || {
  echo "tun-gw not ready yet; run: sudo systemctl start agent-vm-route.service"
}

echo "panel: http://127.0.0.1:${PANEL_PORT:-11088}"
