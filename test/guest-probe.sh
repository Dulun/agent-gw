#!/usr/bin/env bash
# Runs INSIDE the guest (fed over ssh stdin by test/leak.sh and the panel's full test).
# Prints key=value lines. Every probe is its own background job: a serial version took ~40s
# and the browser looked hung; the wall time is now the slowest single probe (~8s).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
c() { timeout 5 curl -s -m 5 "$@" 2>/dev/null | tr -d '\r\n' | head -c 60; }
probe() { timeout 4 curl -s -m 3 -o /dev/null "$1" >/dev/null 2>&1 && echo OPEN || echo BLOCKED; }
conn() { timeout 3 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1 && echo OPEN || echo BLOCKED; }
emit() { local k="$1"; shift; ( printf '%s=%s\n' "$k" "$( "$@" 2>/dev/null )" ) >"$TMP/$k" & }
stun_udp() { python3 - <<'PY'
import socket
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2)
    s.sendto(b"\x00\x01\x00\x00\x00\x00\x00\x00",("74.125.250.129",19302))
    s.recvfrom(64); print("ANSWER")
except Exception: print("BLOCKED")
PY
}
doh_egress() { local ip; ip=$(c -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=ifconfig.me&type=A' | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"'); [ -n "$ip" ] && c --resolve "ifconfig.me:443:$ip" https://ifconfig.me/ip; }
dot_egress() { local ip; ip=$(timeout 5 dig +time=2 +tries=1 +tls +short @8.8.8.8 ipinfo.io 2>/dev/null | grep -oE '^[0-9.]+' | head -1); [ -n "$ip" ] && c --resolve "ipinfo.io:443:$ip" https://ipinfo.io/ip; }
akamai() { timeout 4 dig +time=2 +tries=1 +short whoami.akamai.net @1.1.1.1 2>/dev/null | grep -oE '^[0-9.]+' | head -1; }
v6() { c -6 https://api64.ipify.org; }
pub_http() { timeout 8 curl -s -m 8 -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null; }
ntp() { timeout 4 python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(2);s.sendto(b"\x1b"+47*b"\0",("pool.ntp.org",123));s.recvfrom(48);print("ANSWER")' 2>/dev/null || echo BLOCKED; }

emit IP_IPINFO     c https://ipinfo.io/ip
emit IP_IFCONFIG   c https://ifconfig.me/ip
emit IP_ICANHAZ    c https://icanhazip.com
emit IP_IPIFY      c https://api.ipify.org
emit IP_IPAPI      c 'http://ip-api.com/line/?fields=query'
emit V6            v6
emit DOH_EGRESS    doh_egress
emit DOT_EGRESS    dot_egress
emit AKAMAI        akamai
emit STUN_UDP      stun_udp
emit STUN_TCP      probe http://74.125.250.129:3478/
emit HOST_SSH      conn 192.168.122.1 22
emit HOST_PANEL    conn 192.168.122.1 11088
emit HOST_MIHOMO   conn 192.168.122.1 11095
emit HOST_CTRL     conn 192.168.122.1 11098
emit HOST_DNS      conn 192.168.122.1 1053
emit LAN_GW        probe http://192.168.0.1/
emit LAN_PEER      probe http://192.168.0.138/
emit META          probe http://169.254.169.254/
emit OTHER_VM      conn 192.168.122.50 22
emit PUB_HTTP      pub_http
emit NTP           ntp

wait
for f in "$TMP"/*; do cat "$f"; done
echo "TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
echo "LOCALE=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}')"
echo "EPOCH=$(date +%s)"
