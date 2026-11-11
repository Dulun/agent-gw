# agent-gw install/reinstall entry point: idempotent, safe to rerun.
# Generates secrets -> renders config -> starts containers -> installs killswitch.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ -f .env ] || { cp .env.example .env; echo "created .env, edit it first (nodes)"; }
set -a; . ./.env; set +a

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

# Node source: either one
if [ -n "${PROXY_PROVIDER_URL:-}" ]; then
  echo "fetching proxy-provider..."
  curl -fsSL --max-time 30 "$PROXY_PROVIDER_URL" -o /tmp/agw-providers.yaml
  python3 - /tmp/agw-providers.yaml gw-data/config.yaml <<'EOF'
import sys, yaml
src = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
dst = yaml.safe_load(open(sys.argv[2], encoding='utf-8')) or {}
proxies = src.get('proxies') or []
if not proxies:
    sys.exit('provider returned no proxies')
names = [p['name'] for p in proxies if 'name' in p]
dst['proxies'] = proxies
for g in dst.get('proxy-groups') or []:
    if g.get('name') == 'EXIT':
        g['proxies'] = names
yaml.safe_dump(dst, open(sys.argv[2], 'w', encoding='utf-8'), allow_unicode=True)
print(f"merged {len(names)} proxies")
EOF
elif [ -n "${PROXY_STATIC_YAML:-}" ]; then
  python3 - gw-data/config.yaml <<'EOF'
import os, sys, yaml
static = yaml.safe_load(os.environ['PROXY_STATIC_YAML']) or []
p = sys.argv[1]
d = yaml.safe_load(open(p, encoding='utf-8')) or {}
names = [x['name'] for x in static if 'name' in x]
d['proxies'] = static
for g in d.get('proxy-groups') or []:
    if g.get('name') == 'EXIT':
        g['proxies'] = names
yaml.safe_dump(d, open(p, 'w', encoding='utf-8'), allow_unicode=True)
print(f"merged {len(names)} static proxies")
EOF
fi

# Sidecar for the panel (read-only node server display)
python3 - gw-data/config.yaml <<'EOF' 2>/dev/null || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
with open('gw-data/node-server-ip.env', 'w', encoding='utf-8') as f:
    for p in d.get('proxies') or []:
        f.write(f"{p.get('name','')}={p.get('server','')}\n")
EOF

docker compose build
docker compose up -d --remove-orphans

# killswitch (host nft, always on)
sudo install -m 0644 agent-vm-guard.service agent-vm-route.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now agent-vm-guard.service
VM_IP="$VM_IP" VM_MAC="$VM_MAC" SSH_PORT="$SSH_PORT" TABLE="$TABLE" \
  DNS_TARGET="192.168.122.1:${DNS_PORT:-1053}" HOME_CIDR="$HOME_CIDR" sudo -E ./agent-vm-route.sh guard
# route waits for tun-gw
sudo systemctl enable --now agent-vm-route.service || {
  echo "tun-gw not ready yet; run: sudo systemctl start agent-vm-route.service"
}

echo "panel: http://127.0.0.1:${PANEL_PORT:-11088}"
