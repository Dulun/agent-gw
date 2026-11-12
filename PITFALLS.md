# PITFALLS

Failures that already happened here, in the order they bit. Each entry is symptom -> cause -> fix,
so the next rebuild does not rediscover them.

## 1. Guest leaks the home IP while the killswitch reports ON

Symptom: `curl https://ipinfo.io` inside the guest returns the home ISP IP; panel says
`killswitch: ON`; the nft drop counter stays at 0.

Cause: mihomo ran `mode: global` with no `GLOBAL` selector defined. In that state mihomo silently
falls back to the built-in `DIRECT` and dials from the host itself. The nft guard only hooks
`forward`, so it never sees host-originated (OUTPUT) connections. The leak was invisible while the
desktop TUN was up, because that TUN swallowed the direct dial and re-proxied it — so it looked
like the gateway was working. Turning the desktop TUN off exposed it.

Fix: `mode: rule`, `rules` ending in `MATCH,EXIT`, and a `GLOBAL` select group pointing at `EXIT`.
`setup.sh` now aborts before starting containers if any group can select `DIRECT` or if global mode
lacks a `GLOBAL` group.

## 2. Guest egress changes when the desktop proxy is toggled

Symptom: with the host TUN on the guest exits through the host's node; with it off the guest leaks
or dies.

Cause: the gateway container uses `network_mode: host`, so its dial to the node server is routed by
the host. A desktop TUN with `auto-route: true` owns the default route and captures that dial.

Fix: `pin_nodes` in `agent-vm-route.sh` adds `<node-ip>/32 via <gw> dev <home-if>` in the main
table for every proxy `server`. A host route beats the TUN's default route. Runs from
`agent-vm-route.service` at boot.

Note: `server` values that are domains are pinned by their resolved IP; restart the unit after a
DNS change.

## 3. Restarting the route unit removes the killswitch

Symptom: after `systemctl restart agent-vm-route`, the panel flips to `killswitch: OFF`.

Cause: the unit was `ExecStart=... route`, `ExecStop=... down`, and `down` tore down both the policy
route and the nft guard.

Fix: split teardown into `unguard` and `unroute`; the guard unit stops with `unguard`, the route
unit stops with `unroute`, and the route unit starts with `up` so it re-asserts both halves.

## 4. `VM_MAC is empty` and the guard refuses to start from systemd

Symptom: `agent-vm-guard.service` fails with `VM_MAC is empty` even though `.env` has it.

Cause: units carried no `EnvironmentFile`, and heredocs do not inherit an interactive shell.

Fix: `agent-vm-route.sh` sources `.env` and `vm.env` from its own directory before defaults.
Keeping the units path-free is deliberate: the repo can move.

## 5. First boot ignores the injected SSH keys

Symptom: `Permission denied (publickey)` although `cloud-init` reported success; authorized_keys
still contains the golden image's old keys.

Cause: the golden image already ran cloud-init for an older `instance-id`, so
`once-per-instance` modules were restored from cache and skipped.

Fix: `vm/setup-vm.sh` writes a fresh `instance-id` into the seed. For an already-booted guest,
`cloud-init clean --logs` (offline via `virt-customize`, or `cloud-init clean` + reboot) forces a
rerun. Rotating the seed alone is not enough while the cached instance id matches.

## 6. UEFI guest will not boot from the golden qcow2

Symptom: virt-manager ends with "not a bootable disk".

Cause: two separate mistakes — picking *Local install media (ISO)* for an existing disk image, and
booting SeaBIOS against an image built for OVMF + secure boot.

Fix: `Installation type = Import existing disk image`, and `Firmware = UEFI x86_64`. The repo does
this in `vm/setup-vm.sh` through `virt-install --boot uefi --import`.

## 7. `Duplicate node key` in Tailscale after cloning the golden image

Symptom: the new guest cannot join; the admin console shows duplicate node keys; the guest reports
another machine's hostname.

Cause: the golden image was cloned with `/var/lib/tailscale/tailscaled.state` inside, so both copies
present the same machine key.

Fix: `tailscale logout`, stop `tailscaled`, delete `tailscaled.state`, start, then
`tailscale login --hostname=<new>`. Rename afterwards with `tailscale set --hostname=<name>`.
Delete the stale entries in the admin console; otherwise a later login re-creates suffixed names.

## 8. `tailscale login` prints no URL and hangs

Symptom: `tailscale login` returns `context canceled`, daemon log says `StartLoginInteractiveAs(...): url=false`.

Cause: the desktop client's TUN used `fake-ip-range` covering everything with `fake-ip-filter: '*'`.
Control-plane DNS resolved to a fake IP; tailscaled bypasses the TUN by design (fwmark), so it
dialled the fake address and never got a real answer.

Fix: turn the desktop TUN off while logging in (or add `+.tailscale.com` and `+.ts.net` to
`fake-ip-filter`). The gateway's own TUN is unrelated to this.

## 9. Compose mounts the wrong `gw-data`

Symptom: mihomo logs `Can't find config, create a initial config file` and listens on the default
`7890`.

Cause: the volume was written as `../gw-data`, which compose resolved relative to the project
directory, not the repo root.

Fix: `./gw-data`, and verify with `docker inspect <container> --format '{{json .Mounts}}'`.

## 10. Multi-line YAML in `.env` breaks `source`

Symptom: `setup.sh` sets a handful of variables and silently loses the rest; `xargs: Unterminated quote`.

Fix: `.env` holds single-line values only. Proxy lists live in `nodes.yaml` (gitignored) and
`setup.sh` merges them with PyYAML.

## 11. Template placeholders that the renderer cannot see

Symptom: a rendered config contains a literal `${...}`, or the render crashes.

Cause: the renderer only understands `${NAME}` and `${NAME:-default}`. `${API_SECRET:?message}`
breaks it, and an unquoted `[${TUN_ADDR:-198.19.0.1/30}]` breaks YAML before rendering.

Fix: use the two supported forms only, and quote anything containing `:` or `/`.

## 12. mihomo refuses rules that reference a missing target

Symptom: `Parse config error: proxy ["EXIT"] not found`, and the container restarts forever.

Cause: an empty `proxies: []` list leaves `proxy-groups[].proxies` empty, and rules cannot target a
bare proxy name that was never defined.

Fix: `setup.sh` fills `EXIT` with the actual node names after merging, and keeps `MATCH,EXIT`.
`gateway/config.example.yaml` alone is not a runnable config — it is a template.

## 13. Guest clock is in the wrong zone

Symptom: guest logs are eight hours off and TLS/session timestamps look wrong.

Cause: the cloud-init template inherited `timezone: Asia/Shanghai` from another host's setup.

Fix: `VM_TZ` in `vm.env` (default `America/Los_Angeles`), rendered into the template. For a running
guest: `timedatectl set-timezone <zone>`.

## 14. Direct DNS upstream remains after the traffic is forced through the node

Symptom: everything looks proxied, but the resolver is still queried in the clear from the host.

Cause: `nameserver: ['tls://223.5.5.5:853', ...]`, no proxy suffix.

Fix: `nameserver: ['tls://1.1.1.1:853#EXIT']` — the `#EXIT` suffix routes the query through the node,
so a dead node also kills DNS (intended).

## 15. `ssh root@<tailnet-ip>` hangs instead of failing

Symptom: the terminal sits at the connect prompt with no error.

Cause A: `ssh <ip>` uses the local username, which does not exist in the guest.
Cause B: the golden image was rebuilt, so the host key changed and the stale `known_hosts` entry
blocks authentication (no `BatchMode`, so it waits).

Fix: `ssh root@<ip>` and `ssh-keygen -R <ip>`. This is unrelated to any proxy issue.

## 16. `sudo -E` does not pass variables

Symptom: `sudo: preserving the entire environment is not supported, '-E' is ignored`, then the
script sees empty values.

Fix: `sudo env VAR=value ... ./script.sh`, which `setup.sh` does.

## 17. Stopping the units opened the guest

Symptom: `systemctl stop agent-vm-guard` left the guest with a direct path again.

Cause: the guard lived only in the script-owned table, and `unguard` deleted it. A reboot where the
unit failed, or a manual flush, produced the same hole.

Fix: `persist_lock` writes an identical `agentvm_lock` table into `/etc/nftables.conf` and enables
`nftables.service`. Nothing in this repo deletes that table, so the guest stays blocked even with
both units stopped, the dynamic table flushed, or `nftables.service` reloaded. The file uses
`add table` + `delete table` before defining itself so reloading it never stacks duplicate rules.
It deliberately contains no `flush ruleset`; docker and libvirt own other tables.

## 18. Blackholing the node also breaks the desktop client

Symptom: while testing "node down", the desktop proxy panel showed the same node as Timeout.

Cause: `ip route add blackhole <node>/32` is host-wide; the desktop client dials the same server.

Fix: acceptable for a short test — the matrix script removes it in a `trap ... EXIT`. Use
`ip route add blackhole <ip>/32` / `ip route del blackhole <ip>/32`; `ip route replace ... blackhole`
is rejected with `Invalid argument`, and a `blackhole` route makes `ip route get` itself fail.

## 19. A test that probes during container boot lies

Symptom: "baseline" reported BLOCKED, and every later restore reported BLOCKED, although the stack
was fine seconds later.

Cause: `docker restart` returns before mihomo has created `tun-gw` and completed the node handshake,
so the probe raced the boot.

Fix: `wait_for` polls until the expected state is observed twice, 3s apart. Any scenario script must
wait for stability, not for a fixed sleep.

## 12. The guest could reach the home LAN and this host directly

Symptom: from the guest, `curl 192.168.0.1` answered and `ssh 192.168.122.1` was open.

Cause: `agent-vm-route.sh guard` accepted `oifname virbr0` and `ip daddr $HOME_CIDR`, and table
200 carried a `HOME_CIDR dev $HOME_IF` route. Both were deliberate in the first version ("guest may
use the LAN") and both are a bypass of the tunnel.

Fix: the forward chain accepts only `oifname tun-gw`; the `HOME_CIDR` route and accept rules are
gone; an input chain drops guest traffic to the host except the DNS proxy port; mihomo rejects
private/metadata destinations so they cannot be tunnelled either. S12/S13 in `test/matrix.sh`.

## 13. IPv6 came from the golden image, not from a policy

Symptom: `disable_ipv6=1` held only because that image had it; a rebuilt guest would have had a
working v6 stack, and the guard had no v6 rule at all.

Fix: `vm/user-data.template.yaml` writes `/etc/sysctl.d/99-agent-vm.conf`, and both guard layers
drop `meta nfproto ipv6` before any accept rule. S14 checks it.

## 14. The guest clock drifted once NTP was gone

Symptom: after removing the guest's network path to NTP, the clock drifted and timestamps in logs
stopped matching the host.

Fix: `agent-vm-clock.timer` runs `virsh domtime <vm> --sync` every minute over qemu-guest-agent;
the guest timezone stays `America/Los_Angeles` and `systemd-timesyncd` is disabled in cloud-init.

## 15. `docker compose build` cannot reach Docker Hub from this host

Symptom: `failed to resolve source metadata for docker.io/library/python:3.13-alpine: dial tcp
31.13.95.38:443: i/o timeout` (a poisoned DNS answer), while the running stack is fine.

Cause: DNS for `registry-1.docker.io` resolves to a junk address when no proxy is in the path; the
daemon has no proxy configured, so any rebuild needs Docker Hub directly.

Fix: `setup.sh` builds only when the image is missing (`FORCE_BUILD=1` to force). Building the
panel image on such a host needs the build proxy explicitly:
`DOCKER_BUILDKIT=0 docker build --network host --build-arg https_proxy=$HOST_PROXY -t agent-gw-panel:latest panel`
(`docker compose build` cannot reach the registry here).

## 16. A config edit did not reach the running mihomo

Symptom: `gw-data/config.yaml` had the new `IP-CIDR,...,REJECT` rules, `/rules` still showed two.

Cause: the config is a bind-mounted file; `docker compose up -d` only compares service definitions,
so a changed file does not restart the container.

Fix: `setup.sh` uses `up -d --remove-orphans --force-recreate`.

## 17. WebRTC had a TCP path and UDP was open

Symptom: a page in the guest could open STUN/TURN flows; only 3478/5349/19302 were rejected.

Fix: the guard drops all guest UDP at the forward hook (WebRTC, QUIC, mDNS, NTP), mihomo adds
`NETWORK,UDP,REJECT` as a second layer, and DNS keeps working because it is dnat'd to the host.
`test/leak.sh` probes STUN over UDP and TCP every round.

## 18. Global mode is only safe when GLOBAL is defined

Symptom: `GLOBAL.now = DIRECT` even though the template said `GLOBAL -> EXIT`.

Cause: `merge_nodes()` rewrote `proxy-groups` to just `EXIT`; mihomo then created its own `GLOBAL`
defaulting to `DIRECT`. Rule mode hid it, and one API call to `mode: global` would have leaked
from the host, where the FORWARD-only guard cannot see the dial.

Fix: the renderer writes `GLOBAL -> EXIT` explicitly, the assertion rejects a global config whose
`GLOBAL` is not exactly `['EXIT']`, the container watchdog re-asserts `mode: global` and
`GLOBAL: EXIT` every 10s, and the panel checks the live group. Private/metadata destinations moved
into nft because global mode ignores proxy rules.
