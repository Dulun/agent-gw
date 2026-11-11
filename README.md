# agent-gw

Single-NIC transparent proxy for one KVM guest (`agent-vm`), with an always-on
fail-closed killswitch and a single Web panel. No second NIC, no Wi-Fi isolation
segment: the guest's traffic either exits through the dedicated mihomo TUN
interface or is dropped. It never falls back to direct.

| Path | Role |
|---|---|
| `setup.sh` | only entry point: vm -> config render -> containers -> killswitch |
| `.env` / `.env.example` + `nodes.yaml` | machine config + private nodes (gitignored) |
| `vm/` | KVM guest definition: `setup-vm.sh` + cloud-init templates |
| `gateway/config.example.yaml` | mihomo template rendered by `setup.sh` |
| `gateway/Dockerfile` | mihomo baked in at build time (pinned version) |
| `panel/` | the only Web UI: status + node switch (`:PANEL_PORT`) |
| `agent-vm-route.sh` | host nft guard + policy table 200 |
| `agent-vm-{guard,route}.service` | systemd units (guard runs before libvirt) |
| `gw-data/` | rendered runtime state (gitignored) |
| `AGENTS.md` / `PITFALLS.md` | invariants for coding agents; every trap already hit |

## How it works

- `gateway-core` runs mihomo with `auto-route: false`. It owns exactly one
  interface, `tun-gw`, and never touches the host main table.
- `agent-vm-route.sh guard` (nft, matched by guest MAC) allows the guest only
  onto `tun-gw`, `virbr0`, or the home CIDR. Everything else drops. Missing
  TUN means no network, not a direct leak. Runs before libvirt at boot.
- `agent-vm-route.sh route` adds `from VM_IP table 200` with default via
  `tun-gw`; guest DNS is hijacked to the gateway mihomo (`:1053`).
- Panel shows killswitch state (read-only, always on), egress IP, node list.

## Rules that keep it fail-closed

- `mode: rule` + `MATCH,EXIT`; no group may reach `DIRECT`.
- A `GLOBAL` group points at `EXIT`, so an API mode switch cannot fall back to `DIRECT`.
- Node server IPs are pinned `/32` through the physical NIC, so the host's desktop TUN cannot
  capture the gateway's own dial.
- DNS upstream goes through `#EXIT`; a dead node kills DNS too.

See [AGENTS.md](AGENTS.md) for the full invariant list and [PITFALLS.md](PITFALLS.md) for the
failures that produced them.

## Requirements

- Linux host with KVM/libvirt, Docker, `nftables`, `virbr0` (`192.168.122.1`)
- A KVM guest with a static IP (default `192.168.122.200`) on `virbr0`
- A proxy subscription used **only** by this gateway (stable egress for the VM)

## Quick start

```bash
cp .env.example .env && cp vm/vm.env.example vm.env && cp nodes.yaml.example nodes.yaml
# edit .env: VM_MAC, HOME_CIDR/HOME_IF
# edit vm.env: GOLDEN_IMAGE (your golden qcow2), SSH_PUBKEYS
# edit nodes.yaml: proxy list for this VM (or set PROXY_PROVIDER_URL in .env)
./setup.sh
# panel: http://127.0.0.1:11088
```

Rerun `./setup.sh` after `git pull`, reboot, or node rotation. It is idempotent.

## Verify the killswitch

```bash
sudo ./agent-vm-route.sh status
# inside the guest: curl https://ipinfo.io/json  -> gateway egress IP
# stop the core: docker stop agent-gw-core
# inside the guest: curl times out (dropped), never the home IP
docker start agent-gw-core
```
