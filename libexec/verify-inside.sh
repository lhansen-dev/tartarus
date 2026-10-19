#!/bin/sh
# shellcheck disable=SC2015 # pass/bad only echo, so A && B || C is safe here
# Runs inside a sandbox (passed in by `tartarus verify`). Exits non-zero if any wall is down.
# Args: newline-separated hosts that must be blocked, newline-separated host paths tartarus
# mounted, then host IPs to prove unreachable (the host's LAN/VPN addresses).
# Runs as root: the agent's processes share the agent's uid, and with no Yama in the VM they could
# ptrace a verify running as the agent and rewrite its results. Checks that need the agent's view
# go through as_agent; the agent's files are only ever read. Only system dirs on PATH, and no rc
# files or user site-packages (python3 -I, curl -q, root's HOME), so nothing the agent planted runs.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root; export HOME
blocked="$1"; mounted="$2"; shift 2
fail=0
pass() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }
[ "$(id -u)" = 0 ] || { bad "verify-inside needs root (sbx exec -u root)"; exit 1; }
agent_uid=1000
ahome="$(getent passwd "$agent_uid" | cut -d: -f6)"; ahome="${ahome:-/home/agent}"
# sbx exec adds the sudo and docker groups to every agent session, whatever /etc/group says.
agent_groups="$agent_uid"
for g in sudo docker; do gid="$(getent group "$g" | cut -d: -f3)"; [ -n "$gid" ] && agent_groups="$agent_groups,$gid"; done
as_agent() { setpriv --reuid="$agent_uid" --regid="$agent_uid" --groups="$agent_groups" -- "$@"; }
# The shell's own test: this image's /usr/bin/test (uutils) reads mode bits and misses read-only mounts.
# shellcheck disable=SC2016 # $1 is for the inner sh
agent_can_write() { as_agent sh -c 'test -w "$1"' sh "$1"; }

# Direct TCP, bypassing the proxy. Prints "open" only if real data comes back: sbx's
# interceptor accepts every connect and then closes it empty, so a bare connect proves nothing.
tcp() {
  python3 -I - "$1" "$2" <<'EOF'
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
http() { curl -q -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null; }

echo "secrets"
# Proxy-managed credentials show up as sentinel values, which are safe.
if env | grep -E '^(VAULT_|AWS_|OP_|GH_TOKEN=|GITHUB_TOKEN=|ANTHROPIC_API_KEY=|OPENAI_API_KEY=|KUBECONFIG=)' \
  | grep -vE 'proxymanaged|proxy-managed'; then bad "host secrets in env"; else pass "no host secrets in env"; fi
if ssh-add -l >/dev/null 2>&1; then bad "SSH agent reachable"; else pass "no SSH agent"; fi
# Real credentials stay on the host; the agent's config should only ever hold proxy sentinels.
# JWTs (OAuth), Anthropic/OpenAI keys, GitHub tokens, AWS key IDs, Slack tokens, private keys.
# -D skip: a FIFO the agent left in place of a file would hang a read.
if grep -D skip -rlsE 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|sk-(ant-|proj-)?[A-Za-z0-9_-]{30,}|gh[opsu]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[abpr]-[0-9A-Za-z-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY' \
  "$ahome"/.claude "$ahome"/.claude.json "$ahome"/.codex "$ahome"/.copilot "$ahome"/.config "$ahome"/.docker "$ahome"/.gitconfig \
  "$ahome"/.git-credentials "$ahome"/.netrc "$ahome"/.npmrc "$ahome"/.pypirc "$ahome"/.aws "$ahome"/.ssh "$ahome"/.kube \
  /run/secrets 2>/dev/null | grep -v '/projects/'; then
  bad "real-looking tokens in agent config (files above)"; else pass "agent config holds no real tokens"; fi
# Read, not run: kubectl as root on the agent's kubeconfig would run its exec plugins.
if grep -D skip -qsE '^current-context: *[^ "]' "$ahome/.kube/config"; then bad "kube context set"; else pass "no kube context"; fi

agent_root=""
if as_agent sudo -n true 2>/dev/null; then agent_root=1; echo "  info  agent has root (TARTARUS_ALLOW_ROOT=1?)"
else pass "agent has no root"; fi
if agent_can_write /var/run/docker.sock; then echo "  info  agent can use Docker (root in the guest)"; fi
# Root processes (startup commands, dockerd, sbx exec -u root) inherit PID 1's PATH and BASH_ENV,
# which the agent can read: a command it plants or a directory it swaps anywhere on that PATH
# runs as root on the next start. Swapping needs a writable parent and a path that isn't a mount point.
if [ -z "$agent_root" ]; then
  rootpath="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^PATH=//p')"
  swappable=""
  for d in $(echo "${rootpath:-$PATH}" | tr ':' ' '); do
    if [ -e "$d" ] && agent_can_write "$d"; then swappable="$swappable $d"; continue; fi
    while [ "$d" != / ]; do  # any ancestor the agent could rename, with the PATH dir inside it
      if agent_can_write "$(dirname "$d")" && ! mountpoint -q "$d"; then swappable="$swappable $d"; break; fi
      d="$(dirname "$d")"
    done
  done
  [ -z "$swappable" ] && pass "root's PATH holds nothing the agent can change" || bad "agent can change root's PATH:$swappable"
  # Read-only directories still hold links into the agent's files (~/.local/bin/claude into
  # ~/.local/share): root running one of those runs code the agent can edit.
  editable=""
  for d in $(echo "${rootpath:-$PATH}" | tr ':' ' '); do
    for f in "$d"/*; do
      [ -L "$f" ] || continue
      t="$(readlink -f "$f")"
      case "$t" in "$ahome"/*|/usr/local/share/npm-global/*|/tmp/*|/var/tmp/*) ;; *) continue ;; esac
      if agent_can_write "$t" || agent_can_write "$(dirname "$t")"; then editable="$editable $(basename "$f")"; fi
    done
  done
  [ -z "$editable" ] || echo "  info  as root, these run code the agent can edit (use absolute system paths):$editable"
  bashenv="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^BASH_ENV=//p')"
  if [ -n "$bashenv" ] && agent_can_write "$bashenv"; then bad "agent can write $bashenv, which every root bash runs"
  else pass "BASH_ENV file not agent-writable"; fi
fi

# A sandbox outlives its session: a hook, a global instruction file or an extra MCP server the
# agent writes into its own config steers every later session here. A fresh image has none.
planted="$(python3 -I - "$ahome" <<'EOF'
import json, os, re, sys
home = sys.argv[1]
def load(p):  # regular files only, and not too much: the agent chose what's there
    p = os.path.join(home, p)
    if not os.path.isfile(p): return None
    try:
        with open(p, errors="replace") as f: return f.read(1 << 20)
    except OSError: return None
found = []
s = load(".claude/settings.json")
if s:
    try: found += ["~/.claude/settings.json " + k for k in ("hooks", "statusLine", "apiKeyHelper", "env", "awsAuthRefresh", "otelHeadersHelper") if k in json.loads(s)]
    except ValueError: found.append("~/.claude/settings.json unreadable")
s = load(".claude.json")
if s:
    try: found += ["~/.claude.json MCP server " + k for k in (json.loads(s).get("mcpServers") or {}) if k != "mcp-gateway"]
    except ValueError: pass
s = load(".codex/config.toml") or ""
found += ["~/.codex/config.toml MCP server " + k for k in re.findall(r"^\[mcp_servers\.([^.\]]+)\]", s, re.M) if k != "mcp-gateway"]
found += ["~/.codex/config.toml notify"] if re.search(r"^\s*notify\s*=", s, re.M) else []
s = load(".copilot/mcp-config.json")
if s:
    try: found += ["~/.copilot MCP server " + k for k in (json.loads(s).get("mcpServers") or {}) if k != "mcp-gateway"]
    except ValueError: pass
for p in (".claude/CLAUDE.md", ".claude/agents", ".claude/commands", ".codex/AGENTS.md", ".copilot/copilot-instructions.md"):
    if os.path.exists(os.path.join(home, p)): found.append("~/" + p)
print("\n".join(found))
EOF
)"
if [ -n "$planted" ]; then
  echo "  warn  agent config that steers later sessions (fine if you added it; else tartarus rm for a fresh sandbox):"
  echo "$planted" | sed 's/^/          /'
else pass "no hooks, global instructions or extra MCP servers in agent config"; fi

echo "host surfaces"
if [ -S "${XDG_RUNTIME_DIR:-/run/user/1000}/wayland-0" ] || pgrep -f '^/usr/local/bin/clipboard-bridge' >/dev/null; then
  bad "clipboard bridge present"; else pass "no clipboard bridge"; fi
if [ -n "$(ls -A /run/sbx/skills-shared 2>/dev/null)" ]; then bad "host skills shared in"; else pass "no host skills"; fi
# The MCP gateway's mcp-find/mcp-add let any agent pull any server registered on the host into
# its session at runtime, whatever the sandbox was created with. Its catalog must be empty.
if [ -n "${MCP_GATEWAY_URL:-}" ]; then
  mcp() { curl -q -s -m 15 -D "$1" -H "Authorization: Bearer ${MCP_SENTINEL_TOKEN_NAME:-}" ${sid:+-H "Mcp-Session-Id: $sid"} \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$2" "$MCP_GATEWAY_URL" 2>/dev/null; }
  hdr="$(mktemp)"; sid=""
  mcp "$hdr" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tartarus-verify","version":"1"}}}' >/dev/null
  sid="$(sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *//p' "$hdr" | tr -d '\r')"
  mcp /dev/null '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  found="$(mcp /dev/null '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mcp-find","arguments":{"query":""}}}')"
  rm -f "$hdr"
  case "$found" in
    *"No servers found"*) pass "MCP gateway offers no servers" ;;
    *'"tools"'*|*'"result"'*) bad "MCP gateway offers servers to this agent (sbx mcp ls on the host)" ;;
    *) echo "  warn  couldn't query the MCP gateway; check sbx mcp ls on the host" ;;
  esac
fi
# Host paths reach the VM over virtiofs; a read-write one is a host directory the agent can change
# (an extra mounted with :rw, or a mount made outside tartarus).
# mountinfo: optional fields come before the " - " separator, so find the fstype after it.
hostmounts() { awk -v want="$1" '{for (i = 7; i < NF; i++) if ($i == "-") break; if ($(i + 1) == "virtiofs" && (want == "" || $6 ~ /(^|,)rw(,|$)/)) print $5}' /proc/self/mountinfo 2>/dev/null; }
rwhost="$(hostmounts rw)"
# sbx mount adds host paths to a running sandbox (read-write by default), after every check
# run made: anything beyond what tartarus mounted is one of those.
extra="$(hostmounts | grep -vxF -e /run/sandbox/source -e /etc/resolv.conf | { if [ -n "$mounted" ]; then grep -vxF "$mounted"; else cat; fi; })"
if [ -n "$extra" ]; then bad "host paths mounted outside tartarus (sbx mount?), as the VM sees them:"; echo "$extra" | sed 's/^/          /'
else pass "no host mounts beyond tartarus's own"; fi
if [ -n "$rwhost" ]; then echo "  info  writable host mounts (fine if you passed :rw):"; echo "$rwhost" | sed 's/^/          /'
else pass "no writable host mounts"; fi
if [ -d /run/sandbox/source ]; then
  if touch /run/sandbox/source/.tartarus-write-test 2>/dev/null; then
    rm -f /run/sandbox/source/.tartarus-write-test; bad "host repo writable"
  else pass "host repo read-only"; fi
fi

echo "egress"
# The harness's own model API is the one host every sandbox may reach; any HTTP answer will do.
reached=""
for url in https://api.anthropic.com/ https://api.openai.com/ https://api.githubcopilot.com/; do
  case "$(http "$url")" in 000|403) ;; *) reached="$url"; break ;; esac
done
[ -n "$reached" ] && pass "allowed host reachable (proxy works: $reached)" \
  || echo "  warn  no model API reachable; deny results below may be false passes"
# Domain fronting: an allowed host's connection carrying a blocked host's name must not get its page.
if [ -n "$reached" ] && curl -q -s -m 8 -H 'Host: example.com' "$reached" 2>/dev/null | grep -q 'Example Domain'; then
  bad "domain fronting: example.com reached via $reached"; else pass "no domain fronting via the allowed host"; fi
# npm and PyPI are opt-in (TARTARUS_REGISTRIES=1); report which way this sandbox went.
case "$(http https://registry.npmjs.org/)" in 000|403) pass "package registries blocked" ;;
  *) echo "  info  npm reachable (sandbox started with TARTARUS_REGISTRIES=1?)"
     # Reads only: a publish with a token planted in a prompt would upload.
     code="$(curl -q -s -o /dev/null -m 8 -X PUT -d '{}' -w '%{http_code}' https://registry.npmjs.org/tartarus-verify 2>/dev/null)"
     case "$code" in 000|403) pass "npm refuses writes ($code)" ;; *) bad "npm accepts writes ($code): tartarus setup" ;; esac ;;
esac
[ "$(tcp gateway.docker.internal 3128)" = open ] && pass "TCP probe detects an open port (proxy)" \
  || echo "  warn  TCP probe can't see the proxy; direct TCP results below may be false passes"
for url in https://example.com http://example.com https://s3.amazonaws.com https://storage.googleapis.com \
  https://gitlab.com https://pastebin.com http://169.254.169.254/latest/meta-data/ \
  https://dns.google/resolve?name=example.com https://cloudflare-dns.com/dns-query; do  # DoH: DNS past the policy
  code="$(http "$url")"
  case "$code" in 000|403) pass "blocked $url ($code)" ;; *) bad "reached $url ($code)" ;; esac
done
# Hosts tartarus denies on top of the harness kit (connectors, remote control, GitHub...).
for host in $blocked; do  # hostnames: no spaces or globs to split on
  code="$(http "https://$host/")"
  case "$code" in 000|403) pass "blocked $host ($code)" ;; *) bad "reached denied host $host ($code)" ;; esac
done
for target in 1.1.1.1:443 8.8.8.8:53 169.254.169.254:80; do
  [ "$(tcp "${target%:*}" "${target#*:}")" = closed ] && pass "no direct TCP to $target" || bad "direct TCP to $target"
done
for ip in "$@"; do
  for port in 22 80 443 8080 11434; do
    [ "$(tcp "$ip" "$port")" = closed ] && pass "host $ip:$port unreachable" || bad "host $ip:$port reachable"
  done
  case "$ip" in *:*) u="[$ip]" ;; *) u="$ip" ;; esac
  code="$(http "http://$u:8080/")"
  case "$code" in 000|403) pass "host $ip via proxy blocked" ;; *) bad "host $ip via proxy reached ($code)" ;; esac
done
# The proxy runs on the host, so loopback in any spelling sent through it must not reach host
# services (no_proxy would otherwise skip the proxy for these). localtest.me resolves to 127.0.0.1.
proxy="${http_proxy:-${HTTP_PROXY:-}}"
for url in http://127.0.0.1:11434/ http://localhost:8080/ 'http://[::1]:11434/' 'http://[::ffff:127.0.0.1]:8080/' http://0.0.0.0:8080/ http://127.1:11434/ \
  http://2130706433:8080/ http://localtest.me:11434/; do
  code="$(curl -q -s -o /dev/null -m 8 -x "$proxy" -w '%{http_code}' "$url" 2>/dev/null)"
  case "$code" in 000|403) pass "proxy refuses host loopback $url ($code)" ;; *) bad "proxy reached host loopback $url ($code)" ;; esac
done
for port in 22 8080 11434; do
  [ "$(tcp gateway.docker.internal "$port")" = closed ] && pass "gateway:$port unreachable" || bad "gateway:$port reachable"
done
udp() {
  python3 -I - "$1" <<'EOF'
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
