#!/usr/bin/env python3
"""agent-gw panel: killswitch state, VM start/stop, node switch, end-to-end leak test.

The killswitch itself is host nft (agent-vm-route.sh guard) and has no off switch here.
Everything this panel can do is: start/stop the guest, pick one of the configured nodes,
and prove the guest is either on the node's egress or blocked.
"""
import json
import os
import re
import shlex
import subprocess
import threading
import time
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PANEL_PORT", "11088"))
MIHOMO_API = f"http://127.0.0.1:{os.environ.get('CTRL_PORT', '11098')}"
MIHOMO_PROXY = f"http://127.0.0.1:{os.environ.get('MIXED_PORT', '11095')}"
SECRET = os.environ.get("API_SECRET", "")
VM_MAC = os.environ.get("VM_MAC", "")
VM_IP = os.environ.get("VM_IP", "192.168.122.200")
VM_NAME = os.environ.get("VM_NAME", "agent-vm-xlarge")
GUEST_PROBE = os.environ.get("GUEST_PROBE", "/repo/test/guest-probe.sh")
EXPECT_TZ = os.environ.get("VM_TZ", "America/Los_Angeles")
SSH_KEY = os.environ.get("SSH_KEY") or os.path.expanduser("~/.ssh/id_ed25519")
TUN_DEV = os.environ.get("TUN_DEV", "tun-gw")
TABLE = os.environ.get("TABLE", "200")
drops = deque(maxlen=200)
lock = threading.Lock()


def sh(cmd, timeout=8):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def api(path, method="GET", data=None):
    req = urllib.request.Request(MIHOMO_API + path, method=method)
    req.add_header("Authorization", f"Bearer {SECRET}")
    req.add_header("Content-Type", "application/json")
    try:
        body = json.dumps(data).encode() if data else None
        with urllib.request.urlopen(req, data=body, timeout=3) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


def ks_active():
    out = sh("nft list table inet agentvm_guard 2>/dev/null")
    return "ether saddr" in out and VM_MAC in out


def vm_state():
    return sh(f"virsh -q domstate {shlex.quote(VM_NAME)} 2>/dev/null") or "unknown"


def guest(cmd, timeout=12):
    """Run a shell snippet inside the guest over ssh; empty string when unreachable."""
    q = shlex.quote(cmd)
    return sh(
        f"ssh -i {shlex.quote(SSH_KEY)} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        f"-o BatchMode=yes -o ConnectTimeout=5 root@{shlex.quote(VM_IP)} {q}", timeout=timeout)


_ids = {"t": 0.0, "v": {}}
# Last good values: a 5s poll during a core restart (hysteria2 needs ~30s to handshake) used to
# flash "unknown" and an empty node list, which looks like a fault when nothing is wrong.
_last = {"egress": "", "egress_ip": "", "node": "", "nodes": [], "t": 0.0}
_last_lock = threading.Lock()


def guest_ids():
    """Tailscale IPv4 + MagicDNS name, read inside the guest (cached 10s: ssh is not free)."""
    if time.time() - _ids["t"] < 10:
        return _ids["v"]
    v = {}
    try:
        raw = guest("tailscale status --json 2>/dev/null", timeout=8)
        me = (json.loads(raw).get("Self") or {}) if raw.strip().startswith("{") else {}
        v = {"tailscale_ip": (me.get("TailscaleIPs") or [""])[0],
             "magic_dns": (me.get("DNSName") or "").rstrip(".")}
    except Exception:
        v = {}
    _ids.update(t=time.time(), v=v)
    return v


EGRESS_ENDPOINTS = ("https://ifconfig.me/ip", "https://api.ipify.org", "https://ipinfo.io/ip")


def gateway_egress():
    """First IPv4-looking answer from a few echo services; ipinfo rate-limits (429) under the
    guest's own probes, which used to blank the whole check."""
    ph = urllib.request.ProxyHandler({"http": MIHOMO_PROXY, "https": MIHOMO_PROXY})
    opener = urllib.request.build_opener(ph)
    for url in EGRESS_ENDPOINTS:
        try:
            with opener.open(urllib.request.Request(url, headers={"User-Agent": "curl/8.0"}),
                             timeout=8) as r:
                txt = r.read().decode(errors="replace").strip()
        except Exception:
            continue
        m = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", txt)
        if m:
            return m.group(0), m.group(0)
    return "未知", ""


def guest_pipe(script, timeout=90):
    """Feed a script to the guest over ssh stdin; returns its key=value output."""
    try:
        r = subprocess.run(
            ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes",
             "-o", "ConnectTimeout=5", f"root@{VM_IP}", "bash -s"],
            input=script, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def deep_tests():
    """Cage-style network environment test: everything a program inside the guest can try."""
    try:
        script = open(GUEST_PROBE, encoding="utf-8").read()
    except OSError:
        return [{"name": "guest probe file", "ok": False, "detail": GUEST_PROBE}]
    _, gw_ip = gateway_egress()
    out = guest_pipe(script)
    kv = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    res = []

    def add(name, ok, detail=""):
        res.append({"name": name, "ok": bool(ok), "detail": detail})

    def blocked(v):
        return v.strip() in ("", "BLOCKED")

    def is_node(v):
        return v.strip() == gw_ip

    raw = [kv.get(k, "").strip() for k in
           ("IP_IPINFO", "IP_IFCONFIG", "IP_ICANHAZ", "IP_IPIFY", "IP_IPAPI")]
    # An empty answer means blocked or rate-limited, which is safe; any *answer* must be the node.
    echoes = [e for e in raw if re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", e)]
    add("IP echo services -> node only", len(echoes) >= 2 and gw_ip and all(e == gw_ip for e in echoes),
        f"{len(echoes)}/5 answered: " + ",".join(sorted(set(echoes))))
    add("no IPv6 egress", blocked(kv.get("V6", "")), kv.get("V6", "") or "BLOCKED")
    add("DoH lookup still exits via node", is_node(kv.get("DOH_EGRESS", "")) or blocked(kv.get("DOH_EGRESS", "")),
        kv.get("DOH_EGRESS", "") or "BLOCKED")
    add("DoT lookup still exits via node", is_node(kv.get("DOT_EGRESS", "")) or blocked(kv.get("DOT_EGRESS", "")),
        kv.get("DOT_EGRESS", "") or "BLOCKED")
    add("STUN udp/19302 blocked", blocked(kv.get("STUN_UDP", "")), kv.get("STUN_UDP", ""))
    add("STUN tcp/3478 blocked", blocked(kv.get("STUN_TCP", "")), kv.get("STUN_TCP", ""))
    host_ports = ("HOST_SSH", "HOST_PANEL", "HOST_MIHOMO", "HOST_CTRL")
    add("host ports closed to guest", all(blocked(kv.get(k, "")) for k in host_ports),
        ",".join(f"{k[5:].lower()}={kv.get(k)}" for k in host_ports))
    add("home LAN unreachable", all(blocked(kv.get(k, "")) for k in ("LAN_GW", "LAN_PEER")),
        f"gw={kv.get('LAN_GW')} peer={kv.get('LAN_PEER')}")
    add("metadata + other guest unreachable",
        blocked(kv.get("META", "")) and blocked(kv.get("OTHER_VM", "")),
        f"meta={kv.get('META')} vm={kv.get('OTHER_VM')}")
    add("ntp udp/123 blocked", blocked(kv.get("NTP", "")), kv.get("NTP", ""))
    add("public https works", kv.get("PUB_HTTP", "").strip() == "200", kv.get("PUB_HTTP", "") or "-")
    try:
        drift = int(kv.get("EPOCH", "0")) - int(time.time())
    except ValueError:
        drift = 999
    add("guest clock within 2s", abs(drift) <= 2, f"drift={drift}s")
    tz = kv.get("TZ", "").strip()
    add(f"timezone {EXPECT_TZ}", tz == EXPECT_TZ, tz or "-")
    loc = kv.get("LOCALE", "").strip()
    add("locale en_US", loc.startswith("en_US") or loc.startswith("en_"), loc or "-")
    return res


def run_tests():
    """Each check answers one question; `ok` false means a real leak or a dead stack."""
    out = []

    def add(name, ok, detail=""):
        out.append({"name": name, "ok": bool(ok), "detail": detail})

    add("killswitch table present", ks_active(), "inet agentvm_guard")
    add("persistent lock present", bool(sh("nft list table inet agentvm_lock 2>/dev/null")), "/etc/nftables.conf")
    rule = sh(f"ip rule show 2>/dev/null")
    route = sh(f"ip route show table {shlex.quote(TABLE)} 2>/dev/null")
    add("policy route -> tun", f"from {VM_IP}" in rule and TUN_DEV in route, f"table {TABLE}")
    state = vm_state()
    add("guest running", state == "running", state)

    cfg = api("/configs") or {}
    proxies = (api("/proxies") or {}).get("proxies") or {}
    exit_all = (proxies.get("EXIT") or {}).get("all") or []
    g_now = (proxies.get("GLOBAL") or {}).get("now")
    add("no DIRECT fallback",
        cfg.get("mode") == "global" and "DIRECT" not in exit_all and g_now == "EXIT",
        f"mode={cfg.get('mode')} exit={','.join(exit_all) or '?'} global={g_now}")

    gw_label, gw_ip = gateway_egress()
    add("gateway egress", bool(gw_ip), gw_label)

    if state == "running":
        g_ip = guest("curl -s -m 8 https://ipinfo.io/ip", timeout=15).strip()
        add("guest egress == gateway egress", bool(gw_ip) and g_ip == gw_ip, f"guest={g_ip or 'blocked'}")
        host = guest("timeout 3 bash -c '</dev/tcp/192.168.122.1/22' 2>/dev/null && echo OPEN || echo BLOCKED")
        add("guest -> host blocked", host.strip() == "BLOCKED", host.strip() or "no answer")
        # mihomo's TUN completes the handshake before REJECTing, so "did the data flow" is the
        # question, not "did connect() succeed": a real HTTP answer means the LAN was reachable.
        lan = guest("curl -s -m 4 -o /dev/null http://192.168.0.1/ >/dev/null 2>&1 && echo OPEN || echo BLOCKED")
        add("guest -> home LAN blocked", lan.strip() == "BLOCKED", lan.strip() or "no answer")
        v6 = guest("ip -6 addr show scope global 2>/dev/null | grep -c inet6")
        add("guest has no global IPv6", v6.strip() in ("", "0"), f"count={v6.strip() or '?'}")
    return out


def poll():
    while True:
        try:
            d = api("/connections")
            for c in (d or {}).get("connections") or []:
                chains = " ".join(c.get("chains") or [])
                if "REJECT" in chains:
                    m = c.get("metadata") or {}
                    eid = f"{m.get('sourceIP')}->{m.get('host')}:{m.get('destinationPort')}"
                    with lock:
                        if not any(e.get("id") == eid for e in drops):
                            drops.appendleft({"t": time.strftime("%H:%M:%S"), "id": eid,
                                              "dst": m.get("host"), "rule": c.get("rule")})
        except Exception:
            pass
        time.sleep(5)


threading.Thread(target=poll, daemon=True).start()

PAGE = """<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>agent-gw</title>
<style>
:root{--bg:#f4f6f9;--card:#fff;--fg:#0f172a;--muted:#475569;--line:#d8dee7;--ok:#15803d;--bad:#b91c1c;--warn:#b45309;--accent:#2563eb;--accentfg:#fff;--chip:#eef1f6}
@media (prefers-color-scheme:dark){:root{--bg:#0b0f14;--card:#131a22;--fg:#f1f5f9;--muted:#b6c2d1;--line:#2c3a4d;--ok:#4ade80;--bad:#f87171;--accent:#3b82f6;--accentfg:#fff;--chip:#1c2531}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15.5px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:920px;margin:0 auto;padding:28px 20px 64px}
header{display:flex;align-items:center;gap:12px;margin-bottom:4px}
h1{font-size:22px;margin:0;letter-spacing:-.01em}
.sub{color:var(--muted);font-size:13px;margin:0 0 20px}
.pills{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:18px}
.pill{display:inline-flex;align-items:center;gap:7px;background:var(--card);border:1px solid var(--line);border-radius:999px;padding:7px 14px;font-size:14px}
.pill b{font-weight:650}
.pill b{font-weight:600}
.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}
.dot.ok{background:var(--ok)}.dot.bad{background:var(--bad)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:16px}
.card h2{font-size:12.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:650;margin:0 0 14px}
.actions{display:flex;flex-wrap:wrap;gap:8px}
button{font:inherit;font-size:14px;font-weight:550;padding:9px 14px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);cursor:pointer;transition:background .12s,border-color .12s}
button:hover{background:var(--chip)}
button.primary{background:var(--accent);color:var(--accentfg,#fff);border-color:var(--accent)}
button.primary:hover{opacity:.9}
button.danger{color:var(--bad)}
button:disabled{opacity:.45;cursor:default}
.grid2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}
@media (max-width:720px){.grid2{grid-template-columns:1fr}}
.kv{margin:0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:2px 16px}
.kv dt{color:var(--muted);text-transform:uppercase;letter-spacing:.05em;font-size:12px;font-weight:600;padding:9px 0;border-bottom:1px solid var(--line)}
.kv dd{margin:0;color:var(--fg);font:14.5px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:500;padding:8px 0;border-bottom:1px solid var(--line);text-align:right;word-break:break-all}
.kv dt:nth-last-of-type(1),.kv dd:last-of-type{border-bottom:none}
.actions.col{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.actions.col button{width:100%}
.actions.col .wide{grid-column:1/-1}
.nodes{display:flex;flex-wrap:wrap;gap:8px}
.nodes button{font-weight:600}
.nodes button[aria-pressed=true]{background:#e3edff;border-color:#2563eb;color:#1d4ed8;box-shadow:inset 0 0 0 1px #2563eb;cursor:default;opacity:1}
@media (prefers-color-scheme:dark){.nodes button[aria-pressed=true]{background:#16305c;border-color:#60a5fa;color:#dbeafe;box-shadow:inset 0 0 0 1px #60a5fa}}
table{width:100%;border-collapse:collapse}
td{padding:9px 6px;border-bottom:1px solid var(--line);font-size:14.5px;vertical-align:top}
tr:last-child td{border-bottom:none}
td.st{width:64px;white-space:nowrap;font-weight:600;font-size:13px}
td.st.ok{color:var(--ok)}td.st.bad{color:var(--bad)}
td.detail{color:var(--muted);font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;text-align:right;word-break:break-all}
.summary{color:var(--muted);font-size:13px;margin:10px 0 0}
.spin{color:var(--muted);font-size:14px}
.badtext{color:var(--bad)}
</style></head><body><div class="wrap">
<header><h1>agent-gw</h1></header>
<p class="sub">fail-closed egress for <b id="vmname">—</b> · no DIRECT path, ever</p>
<div class="pills">
  <span class="pill"><span class="dot ok" id="ksdot"></span>killswitch <b id="ks">…</b></span>
  <span class="pill"><span class="dot ok" id="vmdot"></span>vm <b id="vm">…</b></span>
  <span class="pill">node <b id="node">…</b></span>
  <span class="pill">blocked <b id="dr">0</b></span>
</div>
<div class="grid2">
<div class="card"><h2>addresses</h2><dl class="kv">
  <dt>egress ip</dt><dd id="egip">…</dd>
  <dt>lan ip</dt><dd id="lan">…</dd>
  <dt>tailscale ip</dt><dd id="tsip">…</dd>
  <dt>magicdns</dt><dd id="mdns">…</dd>
</dl></div>
<div class="card"><h2>controls</h2><div class="actions col">
  <button onclick="act('start')">start vm</button>
  <button onclick="act('stop')">stop vm</button>
  <button class="primary wide" onclick="runTest('/api/test/full')">full network test</button>
  <button onclick="runTest('/api/test')">quick test</button>
  <button class="danger wide" onclick="fetch('/api/reset-conns',{method:'POST'}).then(st)">drop connections</button>
</div></div>
</div>

<div class="card"><h2>nodes</h2><div class="nodes" id="nodes"></div></div>
<div class="card"><h2>checks</h2>
  <table id="test"><tr><td class="spin">not run yet — “full network test” probes the guest end to end (~40s)</td></tr></table>
  <p class="summary" id="summary"></p>
</div>
</div><script>
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
async function st(){try{const r=await (await fetch('/api/status')).json();
 $('ks').textContent=r.ks?'ON':'OFF';$('ksdot').className='dot '+(r.ks?'ok':'bad');
 $('vm').textContent=r.vm;if(r.vmname)$('vmname').textContent=r.vmname;
 if(r.stale)$('node').textContent=r.node+' (last known)';$('vmdot').className='dot '+(r.vm==='running'?'ok':'bad');
 $('node').textContent=r.node;$('dr').textContent=r.drops;
 $('ksdot').style.opacity=r.stale?'.45':'1';
 $('egip').textContent=(r.egress||'').split(' ').pop()||'—';$('lan').textContent=r.lan||'—';
 $('tsip').textContent=r.tailscale_ip||'—';$('mdns').textContent=r.magic_dns||'—';
 $('nodes').innerHTML=r.nodes.map(n=>`<button aria-pressed="${n===r.node}" ${n===r.node?'class="active"':`onclick="sw('${esc(n)}')"`}>${esc(n)}</button>`).join('');
}catch(e){}}
async function sw(n){await fetch('/api/switch-node',{method:'POST',body:JSON.stringify({node:n})});setTimeout(st,1200);}
async function act(a){await fetch('/api/vm/'+a,{method:'POST'});setTimeout(st,2500);}
async function runTest(u){
 const t0=Date.now();
 $('test').innerHTML='<tr><td class="spin" id="tspin">running… 0s</td></tr>';$('summary').textContent='';
 const tick=setInterval(()=>{const e=$('tspin');if(e)e.textContent=`running… ${Math.round((Date.now()-t0)/1000)}s`;},250);
 const ac=new AbortController();const to=setTimeout(()=>ac.abort(),120000);
 try{
  const r=await (await fetch(u,{signal:ac.signal})).json();const c=r.checks;
  $('test').innerHTML=c.map(x=>`<tr><td class="st ${x.ok?'ok':'bad'}">${x.ok?'PASS':'FAIL'}</td><td>${esc(x.name)}</td><td class="detail">${esc(x.detail||'')}</td></tr>`).join('');
  const bad=c.filter(x=>!x.ok).length;
  $('summary').textContent=`${c.length} checks · ${c.length-bad} pass · ${bad} fail · ${new Date().toLocaleTimeString()}`;
 }catch(e){$('test').innerHTML=`<tr><td class="st bad">ERR</td><td colspan="2">${e.name==='AbortError'?'timed out after 120s':esc(e.message)}</td></tr>`;}
 finally{clearInterval(tick);clearTimeout(to);}}
$('vmname').textContent=location.host;
st();setInterval(st,5000);
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def _json(self, o, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps(o).encode())

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            b = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        elif self.path == "/api/status":
            d = api("/proxies") or {}
            g = (d.get("proxies") or {}).get("EXIT") or {}
            eg, eg_ip = gateway_egress()
            live = bool(g.get("now"))
            with _last_lock:
                if live:
                    _last.update(node=g.get("now", ""), nodes=g.get("all") or [])
                if eg_ip:
                    _last.update(egress=eg, egress_ip=eg_ip, t=time.time())
                node = g.get("now") or _last["node"]
                nodes = g.get("all") or _last["nodes"]
                eg = eg if eg_ip else (_last["egress"] or "unknown")
                eg_ip = eg_ip or _last["egress_ip"]
            with lock:
                n = len(drops)
            self._json({"ks": ks_active(), "vm": vm_state(), "vmname": VM_NAME,
                        "node": node or "unknown", "nodes": nodes, "egress": eg, "drops": n,
                        "stale": not (live and eg_ip), "lan": VM_IP, **guest_ids()})
        elif self.path == "/api/test":
            self._json({"checks": run_tests()})
        elif self.path == "/api/test/full":
            self._json({"checks": run_tests() + deep_tests()})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n).decode() or "{}")
        except Exception:
            body = {}
        if self.path == "/api/switch-node" and body.get("node"):
            api("/proxies/EXIT", "PUT", {"name": body["node"]})
            api("/connections", "DELETE")
            self._json({"ok": True})
        elif self.path == "/api/vm/start":
            self._json({"ok": True, "out": sh(f"virsh -q start {shlex.quote(VM_NAME)} 2>&1", timeout=60)})
        elif self.path == "/api/vm/stop":
            self._json({"ok": True, "out": sh(f"virsh -q shutdown {shlex.quote(VM_NAME)} 2>&1", timeout=60)})
        elif self.path == "/api/reset-conns":
            api("/connections", "DELETE")
            self._json({"ok": True})
        else:
            self._json({"ok": False}, 404)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
