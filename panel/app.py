#!/usr/bin/env python3
"""agent-gw single panel: status + node switch. killswitch always-on (host nft), no toggle."""
import json
import os
import re
import socket
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
drops = deque(maxlen=200)
lock = threading.Lock()


def sh(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
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

PAGE = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>agent-gw</title>
<style>body{font-family:system-ui;max-width:640px;margin:2em auto;padding:0 1em;color:var(--fg,black)}
.ok{color:green}.bad{color:red}button{font-size:1em;padding:.4em 1em;margin:.2em}</style></head>
<body><h1>agent-gw</h1>
<p>killswitch: <b id="ks">…</b> · 出口: <b id="eg">…</b> · 当前节点: <b id="node">…</b></p>
<p>拦截: <span id="dr">0</span> 条 <button onclick="fetch('/api/reset-conns',{method:'POST'})">断开全部连接</button></p>
<h2>节点</h2><div id="nodes"></div>
<script>
async function st(){const r=await (await fetch('/api/status')).json();
 ks.textContent=r.ks?'ON ⛔':'OFF ⚠️';ks.className=r.ks?'ok':'bad';
 eg.textContent=r.egress;node.textContent=r.node;dr.textContent=r.drops;
 nodes.innerHTML=r.nodes.map(n=>`<button ${n==r.node?'disabled':''} onclick="sw('${n}')">${n}</button>`).join(' ');}
async function sw(n){await fetch('/api/switch-node',{method:'POST',body:JSON.stringify({node:n})});setTimeout(st,1500);}
st();setInterval(st,5000);</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def _json(self, o, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(o).encode())

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            b = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        elif self.path == "/api/status":
            d = api("/proxies") or {}
            g = (d.get("proxies") or {}).get("EXIT") or {}
            eg = "未知"
            try:
                ph = urllib.request.ProxyHandler({"http": MIHOMO_PROXY, "https": MIHOMO_PROXY})
                with urllib.request.build_opener(ph).open(
                        urllib.request.Request("https://ipinfo.io/json",
                                               headers={"User-Agent": "curl/8.0"}), timeout=4) as r:
                    j = json.loads(r.read().decode())
                    eg = f"{j.get('country','?')} {j.get('ip','?')}"
            except Exception:
                pass
            with lock:
                n = len(drops)
            self._json({"ks": ks_active(), "node": g.get("now", "?"),
                        "nodes": g.get("all", []), "egress": eg, "drops": n})
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
        elif self.path == "/api/reset-conns":
            api("/connections", "DELETE")
            self._json({"ok": True})
        else:
            self._json({"ok": False}, 404)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
