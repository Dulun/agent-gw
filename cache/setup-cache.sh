#!/usr/bin/env bash
# Host-side caches: Verdaccio :4873, Docker Hub :5000, mcr :5001, apt :3142, NFS /srv/ci-cache.
# Idempotent; safe to rerun. Cache data lives in /srv/ci-cache and survives rebuilds.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; . ./.env; set +a
HOST_PROXY="${HOST_PROXY:-http://127.0.0.1:7897}"
CACHE_ROOT="${CACHE_ROOT:-/srv/ci-cache}"

echo "--- cache dirs ---"
sudo install -d "$CACHE_ROOT"/{pnpm,pnpm-cache,npm,toolcache,go-mod,pip,uv,verdaccio,registry-hub,registry-mcr,registry-cache,image-downloads,apt}
# Guests write as uid 1000 (all_squash): repair anything a root process left behind.
sudo find "$CACHE_ROOT"/{pnpm,pnpm-cache,npm,toolcache,go-mod,pip,uv,image-downloads} ! -uid 1000 -exec chown 1000:1000 {} + 2>/dev/null || true
sudo install -d "$CACHE_ROOT/verdaccio/storage"
# shortcut: verdaccio runs as uid 10001 in its image; storage must belong to it
sudo chown 10001:10001 "$CACHE_ROOT/verdaccio/storage"

echo "--- verdaccio config ---"
sed -e "s#^http_proxy: .*#http_proxy: $HOST_PROXY#" \
    -e "s#^https_proxy: .*#https_proxy: $HOST_PROXY#" \
    cache/verdaccio.example.yaml | sudo tee "$CACHE_ROOT/verdaccio/config.yaml" >/dev/null

echo "--- registry containers ---"
# docker pull ignores compose env: pull through the host proxy first (or compose hangs on direct).
for img in "verdaccio/verdaccio:6@sha256:68a4f7c7769846226928f3ef7dcc173d5239d40a138e4fd4b436a38a94f64091" "registry:2.8.3@sha256:2a6992855d017a595610e58ec68ebc68c25ac6184cc91222ff08ad67e547b215"; do
  sudo env "http_proxy=$HOST_PROXY" "https_proxy=$HOST_PROXY" docker pull "$img" || true
done
sudo env HOST_PROXY="$HOST_PROXY" docker compose --file cache/compose.yaml up --detach --remove-orphans
sudo docker restart ci-verdaccio >/dev/null

echo "--- NFS export ---"
sudo install -d /etc/exports.d
sudo install -m 0644 cache/exports /etc/exports.d/agent-gw-cache.exports
# Ubuntu's 8 server threads saturate when the guest hammers the cache; 64 keeps it flowing.
sudo install -d /etc/nfs.conf.d
printf '[nfsd]\nthreads=64\n' | sudo tee /etc/nfs.conf.d/agent-gw.conf >/dev/null
sudo systemctl enable --now nfs-server.service
sudo rpc.nfsd 64 2>/dev/null || true
sudo exportfs -ra

echo "--- apt cache (apt-cacher-ng :3142, virbr0 only) ---"
sudo install -d -o apt-cacher-ng -g apt-cacher-ng "$CACHE_ROOT/apt"
{
  printf 'CacheDir: %s/apt\nBindAddress: 192.168.122.1\nPort: 3142\n' "$CACHE_ROOT"
  printf 'Proxy: %s\n' "$HOST_PROXY"
} | sudo tee /etc/apt-cacher-ng/zz-agent-gw.conf >/dev/null
# virbr0 can come up after apt-cacher-ng: wait for the address instead of failing to bind.
sudo install -d /etc/systemd/system/apt-cacher-ng.service.d
printf '%s\n' '[Unit]' 'After=libvirtd.service network-online.target' '' '[Service]' \
  "ExecStartPre=/bin/sh -c 'until ip -4 addr show dev virbr0 | grep -q 192.168.122.1/; do sleep 1; done'" \
  'TimeoutStartSec=180' 'Restart=on-failure' 'RestartSec=5s' |
  sudo tee /etc/systemd/system/apt-cacher-ng.service.d/agent-gw.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable apt-cacher-ng.service >/dev/null 2>&1
sudo systemctl restart apt-cacher-ng.service

echo "caches up: :4873 npm, :5000 hub, :5001 mcr, :3142 apt, nfs /srv/ci-cache"
