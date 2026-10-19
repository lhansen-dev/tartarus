#!/bin/sh
# shellcheck disable=SC2015 # pass/bad only echo, so A && B || C is safe here
# Runs inside a sandbox (copied in by `tartarus verify`). Exits non-zero if any wall is down.
# Args: host IPs to prove unreachable (the host's LAN/VPN addresses).
fail=0
pass() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

# Direct TCP, bypassing the proxy. Prints "open" only if real data comes back: sbx's
# interceptor accepts every connect and then closes it empty, so a bare connect proves nothing.
tcp() {
  python3 - "$1" "$2" <<'EOF'
import socket, ssl, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    s = socket.create_connection((host, port), timeout=4); s.settimeout(4)
    if port == 443:
        ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        ctx.wrap_socket(s, server_hostname=host); print("open")
    else:
        s.sendall(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n")
        print("open" if s.recv(64) else "closed")
except Exception:
    print("closed")
EOF
}

# HTTP status through the sandbox proxy; 000 = connection refused/blocked.
http() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null; }

echo "secrets"
# Proxy-managed credentials show up as sentinel values, which are safe.
if env | grep -E '^(VAULT_|AWS_|OP_|GH_TOKEN=|GITHUB_TOKEN=|ANTHROPIC_API_KEY=|OPENAI_API_KEY=|KUBECONFIG=)' \
  | grep -vE 'proxymanaged|proxy-managed'; then bad "host secrets in env"; else pass "no host secrets in env"; fi
if ssh-add -l >/dev/null 2>&1; then bad "SSH agent reachable"; else pass "no SSH agent"; fi
# Real credentials stay on the host; the agent's config should only ever hold proxy sentinels.
if grep -rlsE 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|sk-(ant-|proj-)?[A-Za-z0-9_-]{30,}|gh[opsu]_[A-Za-z0-9]{30,}' \
  ~/.claude ~/.claude.json ~/.codex ~/.copilot ~/.config 2>/dev/null | grep -v '/projects/'; then
  bad "real-looking tokens in agent config (files above)"; else pass "agent config holds no real tokens"; fi
if command -v kubectl >/dev/null && kubectl config current-context >/dev/null 2>&1; then
  bad "kube context set"; else pass "no kube context"; fi

if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then echo "  info  agent has root (TARTARUS_ALLOW_ROOT=1?)"
else pass "agent has no root"; fi
if docker ps >/dev/null 2>&1; then echo "  info  agent can use Docker (root in the guest)"; fi

echo "host surfaces"
if [ -S "${XDG_RUNTIME_DIR:-/run/user/1000}/wayland-0" ] || pgrep -f '^/usr/local/bin/clipboard-bridge' >/dev/null; then
  bad "clipboard bridge present"; else pass "no clipboard bridge"; fi
if [ -n "$(ls -A /run/sbx/skills-shared 2>/dev/null)" ]; then bad "host skills shared in"; else pass "no host skills"; fi
if [ -d /run/sandbox/source ]; then
  if touch /run/sandbox/source/.tartarus-write-test 2>/dev/null; then
    rm -f /run/sandbox/source/.tartarus-write-test; bad "host repo writable"
  else pass "host repo read-only"; fi
fi

echo "egress"
[ "$(http https://registry.npmjs.org/)" = 200 ] && pass "allowed host reachable (proxy works)" \
  || echo "  warn  registry.npmjs.org unreachable; deny results below may be false passes"
[ "$(tcp gateway.docker.internal 3128)" = open ] && pass "TCP probe detects an open port (proxy)" \
  || echo "  warn  TCP probe can't see the proxy; direct TCP results below may be false passes"
for url in https://example.com http://example.com https://s3.amazonaws.com https://storage.googleapis.com \
  https://gitlab.com https://pastebin.com http://169.254.169.254/latest/meta-data/ \
  https://dns.google/resolve?name=example.com https://cloudflare-dns.com/dns-query; do  # DoH: DNS past the policy
  code="$(http "$url")"
  case "$code" in 000|403) pass "blocked $url ($code)" ;; *) bad "reached $url ($code)" ;; esac
done
# Hosts tartarus denies on top of the harness kit (connectors, remote control, GitHub...).
while read -r host; do
  code="$(http "https://$host/")"
  case "$code" in 000|403) pass "blocked $host ($code)" ;; *) bad "reached denied host $host ($code)" ;; esac
done < /tmp/tartarus-blocked.txt
for target in 1.1.1.1:443 8.8.8.8:53 169.254.169.254:80; do
  [ "$(tcp "${target%:*}" "${target#*:}")" = closed ] && pass "no direct TCP to $target" || bad "direct TCP to $target"
done
for ip in "$@"; do
  for port in 22 80 443 8080 11434; do
    [ "$(tcp "$ip" "$port")" = closed ] && pass "host $ip:$port unreachable" || bad "host $ip:$port reachable"
  done
  code="$(http "http://$ip:8080/")"
  case "$code" in 000|403) pass "host $ip via proxy blocked" ;; *) bad "host $ip via proxy reached ($code)" ;; esac
done
for port in 22 8080 11434; do
  [ "$(tcp gateway.docker.internal "$port")" = closed ] && pass "gateway:$port unreachable" || bad "gateway:$port reachable"
done
udp() {
  python3 - "$1" <<'EOF'
import socket, sys
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
try:
    s.sendto(q, (sys.argv[1], 53)); s.recvfrom(512); print("open")
except Exception:
    print("closed")
EOF
}
for ip in 8.8.8.8 1.1.1.1; do
  [ "$(udp "$ip")" = closed ] && pass "no direct UDP DNS to $ip" || bad "direct UDP DNS to $ip answered"
done
[ "$(tcp 2606:4700:4700::1111 443)" = closed ] && pass "no direct IPv6 TCP" || bad "direct IPv6 TCP to 2606:4700:4700::1111"
if [ -n "$(dig +short +time=3 +tries=1 example.com 2>/dev/null)" ]; then bad "DNS resolves public names"; else pass "DNS for public names blocked"; fi

[ "$fail" = 0 ] && echo "PASS: all walls standing" || echo "FAIL: see above"
exit "$fail"
