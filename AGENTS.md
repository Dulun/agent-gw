# AGENTS.md

Rules for coding agents working in this repository. Human docs are in [README.md](README.md);
the traps that already cost time are in [PITFALLS.md](PITFALLS.md).

## What this is

One host runs one KVM guest (`agent-vm-xlarge`) whose egress is forced through a dedicated
mihomo container (`agent-gw-core`, own `tun-gw`) with a fail-closed killswitch. The host's own
proxy client is a **separate** instance and must never be able to influence the guest's egress.

| Path | Role |
| --- | --- |
| `setup.sh` | only entry point: vm -> config render -> containers -> killswitch. Idempotent. |
| `.env` / `vm.env` / `nodes.yaml` | machine config and private nodes. Gitignored, never referenced from committed files. |
| `gateway/config.example.yaml` | mihomo template rendered by `setup.sh` from the environment. |
| `gateway/entrypoint.sh` | mihomo + table-200 watchdog inside the container. |
| `panel/app.py` | the only UI, `gw-web` container (host network, privileged): killswitch, egress, node switch, VM start/stop, leak test. |
| `agent-vm-route.sh` | host nft guard, policy table 200, node-route pinning. |
| `agent-vm-{guard,route}.service` | systemd units; guard starts before libvirt. |
| `vm/` | guest definition: `setup-vm.sh` + cloud-init templates. |
| `gw-data/` | rendered runtime state. Gitignored. |

## Invariants

- **Fail closed.** If `tun-gw`, the container, or the node is gone, the guest has no network.
  It must never reach the internet directly. Anything that weakens this is a bug, not a preference.
- **No UDP leaves the guest.** That removes WebRTC (STUN/TURN), QUIC, mDNS and NTP in one rule;
  DNS still works because it is dnat'd to the host, not forwarded. HTTPS falls back to TCP.
- **The guest is v4-only and cannot reach this host.** The forward chain accepts only
  `oifname tun-gw` for the guest MAC and drops IPv6 in both chains; the input chain drops
  guest traffic to the host except the DNS proxy port. Host -> guest stays possible.
- **Two layers of guard.** `agentvm_guard` (dynamic, owned by this repo) and `agentvm_lock`
  (written to `/etc/nftables.conf`, loaded by `nftables.service`, never deleted by this repo).
  Stopping or flushing the dynamic layer must not open a path; only editing `/etc/nftables.conf`
  can relax the lock. Do not move lock rules into the script-owned table.
- **No private destination leaves through the node.** Global mode ignores proxy rules, so the
  RFC1918 / link-local / loopback / metadata block lives in the nft guard itself and applies to
  every mode.
- **No `DIRECT` reachable.** `mode: global` with a `GLOBAL` group that lists exactly `EXIT`, and no
  proxy-group may list `DIRECT`. A global-mode switch to the built-in group would dial from the
  host, where the FORWARD-only nft guard cannot see it, so both the renderer and the container
  watchdog pin `GLOBAL -> EXIT` (watchdog re-asserts `mode` and `GLOBAL` every 10s).
- **Two independent proxies.** The host's desktop client and `agent-gw-core` share nothing but the
  physical NIC. Node server IPs are pinned `/32` through the physical interface by `pin_nodes`,
  because a desktop TUN with `auto-route` otherwise swallows the gateway's own dial.
- **Guard and route are torn down separately.** `unguard` / `unroute` exist so restarting one unit
  never silently removes the other half. `down` is for manual use only.
- **The script loads its own config.** Units carry no `EnvironmentFile`; `agent-vm-route.sh` sources
  `.env` and `vm.env` from its own directory so `VM_MAC` exists at boot.
- **Secrets stay out of git.** Tokens, node credentials and the API secret live in `.env`,
  `vm.env` and `nodes.yaml` only. `setup.sh` renders them into `gw-data/`, which is gitignored.
- **One rendering step.** Templates use `${VAR}` / `${VAR:-default}` only; `setup.sh` substitutes
  them. Do not use shell-only syntax such as `${VAR:?message}` in templates (the renderer's regex
  does not understand it).

## Checks

Light and safe anywhere:

```bash
bash -n setup.sh && bash -n agent-vm-route.sh && bash -n vm/setup-vm.sh
python3 -c "import ast; ast.parse(open('panel/app.py').read())"
python3 -c "import yaml; yaml.safe_load(open('gateway/config.example.yaml'))"
```

Requires the running stack (read-only):

```bash
curl -s http://127.0.0.1:11088/api/status          # ks must be true
curl -s http://127.0.0.1:11088/api/test            # every check must be ok
curl -s http://127.0.0.1:11088/api/test/full       # + in-guest network environment test
sudo ./agent-vm-route.sh status
ssh root@192.168.122.200 'curl -s https://ipinfo.io/json'   # must be the node's egress
```

Negative test, the one that matters (briefly drops the guest's network):

```bash
sudo test/matrix.sh    # all scenarios; PASS means the guest never saw the home IP
test/leak.sh 3         # adversarial hunt inside the guest: echo services, DoH/DoT, STUN, LAN
```

It stops the core, removes the policy route, flushes the dynamic guard, stops both units, reloads
`nftables.service`, and blackholes the node, asserting after each step that the guest is either on
the node's IP or blocked — never the home IP. The blackhole step also breaks the desktop client for
that node while it runs; the script removes it on exit via a trap.

## Conventions

- Shell: `set -Eeuo pipefail`, quote everything, English comments.
- Comments explain *why*; a known limit is marked `shortcut: <limit>, <when to upgrade>`.
- Commits: `type(scope): <emoji> subject`, e.g. `fix(route): 🐛 ...`.
- Never add a second listener for the same guest, and never make the guest depend on the host's
  desktop proxy client.
