#!/usr/bin/env bash
# Checks the sbx commands tartarus builds, using a stub sbx that logs the argv of every call
# that changes something. It keeps settings in $TMP/state, so after setup, audit passes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
cat > "$TMP/sbx" <<EOF
#!/bin/sh
S="$TMP/state"
case "\$*" in
  "settings get "*) cat "\$S/\$3" 2>/dev/null || { [ "\$3" = kit.trustedSigners ] && echo "[]"; }; exit 0 ;;
  "settings set "*) printf '%s\n' "\$4" > "\$S/\$3" ;;
  "settings unset "*) rm -f "\$S/\$3" ;;
  "policy ls --json --created-via approval") cat "\$S/approved" 2>/dev/null || echo '{"rules": []}'; exit 0 ;;
  "policy ls --json"*) [ -f "\$S/broken" ] && exit 1; cat "\$S/policy" 2>/dev/null || echo '{"rules": [{"scope": "global", "resource_type": "network", "decision": "deny", "resources": ["*.prod.yourco.com"]}, {"scope": "global", "resource_type": "http", "decision": "deny", "resources": ["registry.npmjs.org", "pypi.org", "files.pythonhosted.org"], "methods": ["DELETE", "PATCH", "POST", "PUT"]}]}'; exit 0 ;;
  "policy approval ls") cat "\$S/approvals" 2>/dev/null || echo HEADER; exit 0 ;;
  "kit verify "*) exit 0 ;;
  "mcp ls") cat "\$S/mcp" 2>/dev/null || echo "No MCP servers registered"; exit 0 ;;
  "ls --quiet") cat "\$S/sandboxes" 2>/dev/null; exit 0 ;;
  "ls --json") cat "\$S/ls.json" 2>/dev/null || echo "[]"; exit 0 ;;
  "ports "*" --json") cat "\$S/ports.json" 2>/dev/null || echo "[]"; exit 0 ;;
  "secret ls --json") [ -f "\$S/broken-secrets" ] && exit 1; cat "\$S/secrets.json" 2>/dev/null || echo '{"secrets": [{"scope": "global", "name": "anthropic"}], "custom_secrets": []}'; exit 0 ;;
esac
echo "sbx \$*" >> "$TMP/log"
case "\$1" in exec) printf 'from the sandbox: \033]0;t\007\n' ;; esac
EOF
chmod +x "$TMP/sbx"
export PATH="$TMP:$PATH" TARTARUS_BASELINE_KIT=KIT XDG_CONFIG_HOME="$TMP/config"
# Paths like ~/a stand for repos in the tests; keep them, and git's config, away from the real home.
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"
"$ROOT/bin/tartarus" setup >/dev/null || { echo "FAIL: setup on the repo as committed (unsigned policy? tartarus sign-kits)"; exit 1; }
# run writes to the repo it's given (.): use a scratch one, and check this repo comes out untouched.
own_config="$(git -C "$ROOT" config --local -l 2>/dev/null || true)"
git init -q "$TMP/repo" && cd "$TMP/repo"

fails=0
check() { # check "<tartarus args>" "<expected last sbx line>"
  : > "$TMP/log"
  eval "$ROOT/bin/tartarus $1" >/dev/null 2>&1 || true
  local got; got="$(tail -n1 "$TMP/log" | sed -E 's/ --name tartarus-[a-z]+-[^ ]+-[0-9]+//')"
  if [[ "$got" != "$2" ]]; then echo "FAIL: tartarus $1"; echo "  want: $2"; echo "  got:  $got"; fails=1; fi
}

R="run --clone --skills off --cpus 4 --memory 8g --kit KIT --kit $ROOT/kits/no-root"
DC="--deny-network mcp-proxy.anthropic.com --deny-network bridge.claudeusercontent.com"
DC+=" --deny-network downloads.claude.ai --deny-network claude.ai --deny-network console.anthropic.com"
DC+=" --deny-network claude.com --deny-network code.claude.com"
DX="--deny-network github.com --deny-network api.github.com --deny-network codeload.github.com"
DXO="--deny-network releases.openai.com --deny-network files.openai.com --deny-network openai.com"
DXR="$DX $DXO"; DX+=" --deny-network registry.npmjs.org $DXO"
check "run claude" "sbx $R $DC claude ."
check "run codex --name xy --detach ~/a ~/b ~/c:ro ~/d:rw -- -m o3" \
  "sbx $R $DX --name xy --detach codex $HOME/a $HOME/b:ro $HOME/c:ro $HOME/d -- -m o3"
check "run copilot" "sbx $R --deny-network github.com --deny-network api.github.com docker.io/sbx/copilot-kit@sha256:02048b3c37f12fdbaf36d80c1a177f15877ed40acd444c1b58829787e16bb108 ."
export TARTARUS_REGISTRIES=1; check "run claude" "sbx $R --kit $ROOT/kits/registries $DC claude ."
check "run codex" "sbx $R --kit $ROOT/kits/registries $DXR codex ."; unset TARTARUS_REGISTRIES
check "run gemini" ""
check "run claude ~/a/repo ~/a" ""        # extra contains the repo: refused
check "run claude ~/a ~/a/sub:rw" ""      # extra inside the repo: refused
check "run claude ~/a ~/ab" "sbx $R $DC claude $HOME/a $HOME/ab:ro"  # prefix-named sibling is fine
git init -q "$TMP/rwrepo"  # a writable repo keeps its .git read-only
check "run claude ~/a $TMP/rwrepo:rw" "sbx $R $DC claude $HOME/a $TMP/rwrepo $TMP/rwrepo/.git:ro"
check "run claude --kit evil ." ""        # unknown option: refused, not passed to sbx as a path
check "run claude ~/a ~/.ssh" ""          # home dotdir: refused
check "run claude /srv/a $HOME" ""        # all of home: refused
check "run claude ~" ""                   # home as the repo: refused
check "run claude ~/.config/x" ""         # dotdir as the repo: refused
check "run claude /" ""                   # / holds home: refused
check "run claude ~/a /" ""
# The repo itself is mounted read-only: credentials in .git/config or untracked secret files leak.
git init -q "$TMP/sec" && touch "$TMP/sec/.env.example" "$TMP/sec/notes.key.md"
check "run claude $TMP/sec" "sbx $R $DC claude $TMP/sec"
n="$(grep -oE -- '--name [^ ]+' "$TMP/log" | cut -d' ' -f2)"
[[ "$(git -C "$TMP/sec" config "remote.sandbox-$n.tagOpt")" == --no-tags && "$(git -C "$TMP/sec" config fetch.fsckObjects)" == true ]] \
  || { echo "FAIL: run did not protect the repo from the sandbox remote"; fails=1; }
git -C "$TMP/sec" remote add origin https://x:ghp_token@github.com/a/b
check "run claude $TMP/sec" ""
git -C "$TMP/sec" remote set-url origin git@github.com:a/b && git -C "$TMP/sec" config http.https://github.com/.extraheader "AUTHORIZATION: basic eA=="
check "run claude $TMP/sec" ""
git -C "$TMP/sec" config --unset http.https://github.com/.extraheader
mkdir -p "$TMP/sec/deploy" && touch "$TMP/sec/deploy/prod.pem" && echo '*.pem' > "$TMP/sec/.gitignore"
check "run claude $TMP/sec" ""
TARTARUS_ALLOW_SECRET_FILES=1 check "run claude $TMP/sec" "sbx $R $DC claude $TMP/sec"
rm "$TMP/sec/deploy/prod.pem"; touch "$TMP/sec/.env.local"
check "run claude $TMP/sec" ""
rm "$TMP/sec/.env.local"; mkdir -p "$TMP/lib/conf" && touch "$TMP/lib/conf/credentials.json"  # extras aren't repos
check "run claude $TMP/sec $TMP/lib" ""
rm "$TMP/lib/conf/credentials.json"
check "run claude $TMP/sec $TMP/lib" "sbx $R $DC claude $TMP/sec $TMP/lib:ro"
check "rm ab cd" "sbx rm --force cd"
printf 'APPROVAL SANDBOX TITLE\nnet:1 ab x.com:443 d\nnet:2 cd y.com:443 d\nnet:3 ab z.com:443 d\n' > "$TMP/state/approvals"
: > "$TMP/log"; "$ROOT/bin/tartarus" rm ab >/dev/null 2>&1
[[ "$(cat "$TMP/log")" == $'sbx policy approval respond net:1 --option dismiss\nsbx policy approval respond net:3 --option dismiss\nsbx rm --force ab' ]] \
  || { echo "FAIL: rm did not dismiss only its prompts first:"; cat "$TMP/log"; fails=1; }
: > "$TMP/log"; out="$("$ROOT/bin/tartarus" dismiss)"
[[ "$(grep -c 'option dismiss' "$TMP/log")" == 3 && "$out" == *"dismissed 3"* ]] || { echo "FAIL: dismiss all"; cat "$TMP/log"; fails=1; }
grep -q 'option allow' "$TMP/log" && { echo "FAIL: something allowed a prompt"; fails=1; }
rm "$TMP/state/approvals"
check "rm ab --all" ""                    # a flag as a name: refused before anything is removed
# rm cleans the sandbox's own repo (sbx records its workspace), even when run from elsewhere.
git init -q "$TMP/ws" && git -C "$TMP/ws" commit -q --allow-empty -m i && git -C "$TMP/ws" update-ref refs/sandboxes/wsbox/main HEAD
git -C "$TMP/ws" remote add sandbox-wsbox git://127.0.0.1:1/x && git -C "$TMP/ws" config remote.sandbox-wsbox.tagOpt --no-tags
echo "[{\"name\": \"wsbox\", \"workspaces\": [\"$TMP/ws\"]}]" > "$TMP/state/ls.json"
(cd "$TMP" && "$ROOT/bin/tartarus" rm wsbox >/dev/null 2>&1)
[[ -z "$(git -C "$TMP/ws" for-each-ref refs/sandboxes)" && -z "$(git -C "$TMP/ws" config --get-regexp '^remote\.sandbox-wsbox' || true)" ]] \
  || { echo "FAIL: rm left the sandbox's refs or remote in its repo"; fails=1; }
rm "$TMP/state/ls.json"
check "run claude --name --kit ." ""
: > "$TMP/log"; "$ROOT/bin/tartarus" verify -u >/dev/null 2>&1 || true
grep -q 'exec' "$TMP/log" && { echo "FAIL: verify took a flag as a sandbox name"; fails=1; }
check "login codex" "sbx secret set openai --oauth"
# safe runs the harness itself: a stub claude shows what it gets (Claude's own sandbox, fail-closed, scrubbed env).
printf '#!/bin/sh\necho "claude $*" > "%s/safe"; env > "%s/safe-env"\n' "$TMP" "$TMP" > "$TMP/claude"; chmod +x "$TMP/claude"
VAULT_TOKEN=x AWS_SECRET_ACCESS_KEY=y "$ROOT/bin/tartarus" safe claude -c >/dev/null 2>&1 || true
grep -q '"failIfUnavailable": true' "$TMP/safe" && grep -q -- ' -c$' "$TMP/safe" || { echo "FAIL: safe claude: $(cat "$TMP/safe")"; fails=1; }
grep -qE '^(VAULT|AWS)_' "$TMP/safe-env" && { echo "FAIL: safe kept host secrets in the env"; fails=1; }
check "login copilot" "sbx secret set copilot"
check "setup" "sbx daemon restart"

: > "$TMP/log"; "$ROOT/bin/tartarus" setup >/dev/null
for want in "sbx settings set ssh.agentForwardingEnabled false" "sbx settings set clipboard.imagePaste false" \
  "sbx settings set skills.defaultMode off" "sbx policy reset --force" "sbx policy init deny-all" \
  "sbx policy deny network *.prod.yourco.com" "sbx policy deny network --method PUT,POST,PATCH,DELETE registry.npmjs.org" \
  "sbx settings set kit.requireSignature true" "sbx daemon restart"; do
  grep -qxF "$want" "$TMP/log" || { echo "FAIL: setup missing: $want"; fails=1; }
done
grep -qF "sbx settings set kit.trustedSigners [{\"key\": \"$TMP/config/tartarus/kit-signing.pub\"}, {\"identity\": \"https://github.com/docker/sbx-kits-contrib/" "$TMP/log" \
  || { echo "FAIL: setup did not trust the pinned key"; fails=1; }

out="$(TARTARUS_CPUS=2 TARTARUS_BASELINE_KIT="$ROOT/kits/team-baseline" "$ROOT/bin/tartarus" config)"
[[ "$out" == *"allow       (none)"* && "$out" == *"Registries    blocked"* && "$out" == *"Deny (codex)  github.com,"* \
  && "$out" == *"cpus=2 memory=8g"* ]] || { echo "FAIL: config"; echo "$out"; fails=1; }
out="$(TARTARUS_REGISTRIES=1 "$ROOT/bin/tartarus" config)"
[[ "$out" == *"allowed: registry.npmjs.org, pypi.org, files.pythonhosted.org"* ]] || { echo "FAIL: config registries"; echo "$out"; fails=1; }

# Signed policy: setup refuses an unsigned deny list before touching sbx, and a changed signing key.
: > "$TMP/log"; echo evil.example > "$TMP/deny.txt"
TARTARUS_DENY_FILE="$TMP/deny.txt" "$ROOT/bin/tartarus" setup >/dev/null 2>&1 && { echo "FAIL: setup took unsigned deny list"; fails=1; }
[[ ! -s "$TMP/log" ]] || { echo "FAIL: setup changed sbx before refusing"; fails=1; }
cp "$TMP/config/tartarus/kit-signing.pub" "$TMP/pinned"; echo other > "$TMP/config/tartarus/kit-signing.pub"
"$ROOT/bin/tartarus" setup >/dev/null 2>&1 && { echo "FAIL: setup trusted a changed signing.pub"; fails=1; }
TARTARUS_REPIN=1 "$ROOT/bin/tartarus" setup >/dev/null 2>&1 || { echo "FAIL: TARTARUS_REPIN=1 setup"; fails=1; }
cmp -s "$TMP/pinned" "$TMP/config/tartarus/kit-signing.pub" || { echo "FAIL: repin did not pin the repo key"; fails=1; }
# run checks the harness deny list against the pinned key (a wrong key stands in for a tampered list).
check "run claude" "sbx $R $DC claude ."
cp "$ROOT/kits/no-root/spec.yaml" "$TMP/config/tartarus/kit-signing.pub" 2>/dev/null
check "run claude" ""
cp "$TMP/pinned" "$TMP/config/tartarus/kit-signing.pub"

# run refuses a machine that fails audit: a registered MCP server, an allow from an approved prompt.
echo "NAME  COMMAND" > "$TMP/state/mcp"; check "run claude" ""; rm "$TMP/state/mcp"
echo '{"rules": [{"scope": "global", "resource_type": "network", "decision": "allow", "resources": ["evil.example"]}]}' > "$TMP/state/policy"
check "run claude" ""; rm "$TMP/state/policy"
# A hand-added per-sandbox allow counts too; a kit's own (provisioned) allow doesn't.
D='{"scope": "global", "resource_type": "network", "decision": "deny", "resources": ["*.prod.yourco.com"]}'
W='{"scope": "global", "resource_type": "http", "decision": "deny", "resources": ["registry.npmjs.org", "pypi.org", "files.pythonhosted.org"], "methods": ["DELETE", "PATCH", "POST", "PUT"]}'
echo "{\"rules\": [$D, $W, {\"scope\": \"sandbox:ab\", \"resource_type\": \"network\", \"decision\": \"allow\", \"resources\": [\"pastebin.com\"], \"provenance\": {\"created_via\": \"added\"}}]}" > "$TMP/state/policy"
check "run claude" ""
sed -i 's/"added"/"provisioned"/' "$TMP/state/policy"; check "run claude" "sbx $R $DC claude ."; rm "$TMP/state/policy"
# A no_proxy entry would let traffic skip the policy proxy: drift there fails audit too.
echo 10.0.0.0/8 > "$TMP/state/no_proxy.sandbox"; check "run claude" ""; : > "$TMP/state/no_proxy.sandbox"
# Without the registry write denies, audit fails (npm publish would be an upload channel).
echo "{\"rules\": [$D]}" > "$TMP/state/policy"; check "run claude" ""; rm "$TMP/state/policy"
# A tartarus sandbox that lost one of its harness denies fails audit; with all of them it passes.
mkdir -p "$TMP/config/tartarus/sandboxes" && echo "1 2 0" > "$TMP/config/tartarus/sandboxes/cx"
echo '[{"name": "cx", "agent": "codex", "workspaces": []}]' > "$TMP/state/ls.json"
rules="$D, $W"; for h in github.com api.github.com codeload.github.com registry.npmjs.org releases.openai.com files.openai.com; do
  rules+=", {\"scope\": \"sandbox:cx\", \"resource_type\": \"network\", \"decision\": \"deny\", \"resources\": [\"$h\"]}"; done
echo "{\"rules\": [$rules]}" > "$TMP/state/policy"
out="$("$ROOT/bin/tartarus" audit 2>&1)" && { echo "FAIL: audit passed a sandbox missing a deny"; fails=1; }
[[ "$out" == *"cx lost its deny for openai.com"* ]] || { echo "FAIL: audit didn't name the lost deny: $out"; fails=1; }
echo "{\"rules\": [$rules, {\"scope\": \"sandbox:cx\", \"resource_type\": \"network\", \"decision\": \"deny\", \"resources\": [\"openai.com\"]}]}" > "$TMP/state/policy"
"$ROOT/bin/tartarus" audit >/dev/null || { echo "FAIL: audit with all of a sandbox's denies"; fails=1; }
rm "$TMP/state/policy" "$TMP/state/ls.json" "$TMP/config/tartarus/sandboxes/cx"
# Allows a sandbox gains after tartarus first saw it (sbx kit add) fail audit.
echo "1 2 0" > "$TMP/config/tartarus/sandboxes/ka"; echo '[{"name": "ka", "agent": "shell"}]' > "$TMP/state/ls.json"
A='{"scope": "sandbox:ka", "resource_type": "network", "decision": "allow", "resources": ["api.anthropic.com"], "provenance": {"created_via": "provisioned"}}'
echo "{\"rules\": [$D, $W, $A]}" > "$TMP/state/policy"
"$ROOT/bin/tartarus" audit >/dev/null || { echo "FAIL: first audit of a sandbox's allows"; fails=1; }
echo "{\"rules\": [$D, $W, $A, ${A/api.anthropic.com/pypi.org}]}" > "$TMP/state/policy"
out="$("$ROOT/bin/tartarus" audit 2>&1)" && { echo "FAIL: audit passed a sandbox that gained an allow"; fails=1; }
[[ "$out" == *"ka gained allows"*"pypi.org"* ]] || { echo "FAIL: audit allow growth: $out"; fails=1; }
rm -f "$TMP/state/policy" "$TMP/state/ls.json" "$TMP/config/tartarus/sandboxes/ka"*
# A port published beyond loopback is an inbound channel to the agent: audit fails.
echo '[{"name": "pb", "agent": "claude"}]' > "$TMP/state/ls.json"
echo '[{"host_ip": "127.0.0.1", "host_port": 1, "sandbox_port": 9418}]' > "$TMP/state/ports.json"
"$ROOT/bin/tartarus" audit >/dev/null || { echo "FAIL: audit refused sbx's own git daemon port"; fails=1; }
echo '[{"host_ip": "0.0.0.0", "host_port": 2, "sandbox_port": 8000}]' > "$TMP/state/ports.json"
out="$("$ROOT/bin/tartarus" audit 2>&1)" && { echo "FAIL: audit passed a port published beyond loopback"; fails=1; }
[[ "$out" == *"pb publishes 0.0.0.0:2 -> 8000 beyond loopback"* ]] || { echo "FAIL: audit ports: $out"; fails=1; }
rm "$TMP/state/ls.json" "$TMP/state/ports.json"
# sbx failing to answer fails audit, rather than reading as "nothing wrong" (audit runs with set -e off).
echo '{"rules": [{"scope": "sandbox:ab", "decision": "allow", "resources": ["evil.example"]}]}' > "$TMP/state/approved"
check "run claude" ""; rm "$TMP/state/approved"
touch "$TMP/state/broken"; check "run claude" ""; rm "$TMP/state/broken"
touch "$TMP/state/broken-secrets"; check "run claude" ""; rm "$TMP/state/broken-secrets"
# Only model credentials: a github or any other service secret, or a custom one, fails audit.
echo '{"secrets": [{"scope": "global", "name": "github"}], "custom_secrets": []}' > "$TMP/state/secrets.json"; check "run claude" ""
echo '{"secrets": [], "custom_secrets": [{"name": "x", "domain": "evil.example"}]}' > "$TMP/state/secrets.json"; check "run claude" ""
rm "$TMP/state/secrets.json"
check "run claude" "sbx $R $DC claude ."

# Deleting kits/signing.pub must not switch signature checks off (a copy, so the repo is untouched).
mkdir "$TMP/copy" && cp -r "$ROOT/bin" "$ROOT/kits" "$ROOT/policy" "$ROOT/libexec" "$TMP/copy/" && rm "$TMP/copy/kits/signing.pub"
"$TMP/copy/bin/tartarus" audit >/dev/null 2>&1 && { echo "FAIL: audit passed with signing.pub deleted"; fails=1; }
"$TMP/copy/bin/tartarus" setup >/dev/null 2>&1 && { echo "FAIL: setup accepted a deleted signing.pub"; fails=1; }
: > "$TMP/log"; "$TMP/copy/bin/tartarus" run claude >/dev/null 2>&1 || true; [[ ! -s "$TMP/log" ]] || { echo "FAIL: run with signing.pub deleted"; fails=1; }
"$ROOT/bin/tartarus" audit >/dev/null || { echo "FAIL: audit after the copy tests"; fails=1; }
# Dropping signing on purpose: REPIN with no signing.pub turns the requirement off and forgets the pin.
(export XDG_CONFIG_HOME="$TMP/config3"; mkdir -p "$TMP/config3/tartarus" && echo x > "$TMP/config3/tartarus/kit-signing.pub"
 TARTARUS_REPIN=1 "$TMP/copy/bin/tartarus" setup >/dev/null 2>&1) || { echo "FAIL: REPIN setup without a key"; fails=1; }
[[ ! -e "$TMP/config3/tartarus/kit-signing.pub" && "$(cat "$TMP/state/kit.requireSignature")" == false ]] \
  || { echo "FAIL: REPIN without a key left signing half on"; fails=1; }
"$ROOT/bin/tartarus" setup >/dev/null

# A policy line that isn't a hostname is refused, before setup changes anything.
cp -r "$ROOT/policy" "$TMP/badpolicy" && printf 'ok.example\n--all\n' > "$TMP/badpolicy/deny.txt"
: > "$TMP/log"; out="$(TARTARUS_DENY_FILE="$TMP/badpolicy/deny.txt" TARTARUS_SIGNING_KEY=/dev/null "$ROOT/bin/tartarus" config 2>&1 || true)"
[[ "$out" == *"not a hostname: --all"* ]] || { echo "FAIL: bad host not refused: $out"; fails=1; }
out="$(TARTARUS_DENY_FILE="$TMP/badpolicy/deny.txt" "$ROOT/bin/tartarus" audit 2>&1)" && { echo "FAIL: audit passed a malformed deny list"; fails=1; }
[[ "$out" == *"not a hostname: --all"* ]] || { echo "FAIL: audit didn't name the bad deny entry: $out"; fails=1; }

# sign-kits with a fresh key on the copy (signing.pub deleted above), then setup with its own config.
echo '*.evil.example' >> "$TMP/copy/policy/deny-claude.txt"
copy() { TARTARUS_SIGNING_KEY="$TMP/test.key" XDG_CONFIG_HOME="$TMP/config2" "$TMP/copy/bin/tartarus" "$@"; }
copy sign-kits >/dev/null && [[ -s "$TMP/copy/kits/signing.pub" ]] || { echo "FAIL: sign-kits made no key"; fails=1; }
copy setup >/dev/null && copy audit >/dev/null || { echo "FAIL: audit after sign-kits and setup"; fails=1; }
chmod 644 "$TMP/test.key"; copy sign-kits >/dev/null 2>&1 && { echo "FAIL: sign-kits used a world-readable key"; fails=1; }; chmod 600 "$TMP/test.key"
cp "$TMP/copy/kits/signing.pub" "$TMP/team.pub"
TARTARUS_SIGNING_KEY="$TMP/other.key" XDG_CONFIG_HOME="$TMP/config2" "$TMP/copy/bin/tartarus" sign-kits >/dev/null 2>&1 \
  && { echo "FAIL: sign-kits without the team key went ahead"; fails=1; }
cmp -s "$TMP/team.pub" "$TMP/copy/kits/signing.pub" || { echo "FAIL: sign-kits replaced the team's signing.pub"; fails=1; }
(umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TMP/other.key" 2>/dev/null)
TARTARUS_SIGNING_KEY="$TMP/other.key" XDG_CONFIG_HOME="$TMP/config2" "$TMP/copy/bin/tartarus" sign-kits >/dev/null 2>&1 \
  && { echo "FAIL: sign-kits signed with a key that isn't kits/signing.pub"; fails=1; }
# A wildcard deny reaches sbx as written, not globbed against files in the current directory.
mkdir "$TMP/cwd" && touch "$TMP/cwd/a.evil.example"
: > "$TMP/log"; (cd "$TMP/cwd" && copy run claude --name gl "$TMP/sec" >/dev/null 2>&1) || true
grep -qF -- '--deny-network *.evil.example ' "$TMP/log" || { echo "FAIL: wildcard deny entry: $(cat "$TMP/log")"; fails=1; }
# An edit after signing is refused.
echo extra.example >> "$TMP/copy/policy/deny-claude.txt"
: > "$TMP/log"; copy run claude --name gl "$TMP/sec" >/dev/null 2>&1 || true
[[ ! -s "$TMP/log" ]] || { echo "FAIL: run took an edited, unsigned deny list"; fails=1; }
"$ROOT/bin/tartarus" setup >/dev/null  # back to the repo's key for the tests below

# Default names carry a lockdown fingerprint: stable for the same config, new when it changes.
name_of() { : > "$TMP/log"; env "$@" "$ROOT/bin/tartarus" run claude ~/repo >/dev/null 2>&1 || true
  grep -oE -- '--name tartarus-claude-repo-[0-9]+' "$TMP/log"; }
n1="$(name_of X=1)"; n2="$(name_of X=1)"; n3="$(name_of TARTARUS_CPUS=2)"
[[ -n "$n1" && "$n1" == "$n2" && "$n1" != "$n3" ]] || { echo "FAIL: fingerprint names: '$n1' '$n2' '$n3'"; fails=1; }
# Re-attaching by --name needs the config the sandbox was made with; sbx would keep the old one.
"$ROOT/bin/tartarus" run claude --name same "$TMP/a/app" >/dev/null 2>&1 || true
echo same > "$TMP/state/sandboxes"
check "run claude --name same $TMP/a/app -- -c" "sbx run --name same -- -c"  # re-attach: no creation flags
check "run claude --name same $TMP/a/app $TMP/lib:rw" ""
TARTARUS_ALLOW_ROOT=1 check "run claude --name same $TMP/a/app" ""
echo other >> "$TMP/state/sandboxes"; check "run claude --name other $TMP/a/app" ""  # not made by tartarus
# ls: current, made under an older lockdown, or not by tartarus at all.
printf 'same\n' > "$TMP/state/sandboxes"
out="$("$ROOT/bin/tartarus" ls)" || { echo "FAIL: ls of a current sandbox exited $?"; fails=1; }
[[ "$out" == *"same"*"current"* ]] || { echo "FAIL: ls: $out"; fails=1; }
r="$TMP/config/tartarus/sandboxes/same"; awk '{$2 = 1; print}' "$r" > "$r.new" && mv "$r.new" "$r"; printf 'same\nother\n' > "$TMP/state/sandboxes"
rc=0; out="$("$ROOT/bin/tartarus" ls)" || rc=$?
[[ $rc == 1 && "$out" == *"same"*"older lockdown"* && "$out" == *"other"*"not made by tartarus"* ]] || { echo "FAIL: ls stale (exit $rc): $out"; fails=1; }
"$ROOT/bin/tartarus" rm same >/dev/null 2>&1; [[ ! -e "$TMP/config/tartarus/sandboxes/same" ]] || { echo "FAIL: rm kept the record"; fails=1; }
rm "$TMP/state/sandboxes"

# Same basename elsewhere, or the same mount with another mode, is a different sandbox.
name_args() { : > "$TMP/log"; "$ROOT/bin/tartarus" run claude "$@" >/dev/null 2>&1 || true; grep -oE -- '--name [^ ]+' "$TMP/log"; }
mkdir -p "$TMP/a/app" "$TMP/b/app" "$TMP/lib"
na="$(name_args "$TMP/a/app")"; nb="$(name_args "$TMP/b/app")"
nro="$(name_args "$TMP/a/app" "$TMP/lib")"; nro2="$(name_args "$TMP/a/app" "$TMP/lib:ro")"; nrw="$(name_args "$TMP/a/app" "$TMP/lib:rw")"
[[ -n "$na" && "$na" != "$nb" && "$na" != "$nro" && "$nro" == "$nro2" && "$nro" != "$nrw" ]] \
  || { echo "FAIL: fingerprint ignores paths: '$na' '$nb' '$nro' '$nro2' '$nrw'"; fails=1; }
: > "$TMP/log"; "$ROOT/bin/tartarus" run claude "$TMP/my_repo (2)" >/dev/null 2>&1 || true
grep -qE -- '--name tartarus-claude-my-repo--2--[0-9]+ ' "$TMP/log" || { echo "FAIL: name not sanitized: $(cat "$TMP/log")"; fails=1; }
: > "$TMP/log"; "$ROOT/bin/tartarus" run claude --name mine . >/dev/null 2>&1 || true
[[ "$(grep -o -- '--name [^ ]*' "$TMP/log")" == "--name mine" ]] || { echo "FAIL: explicit --name overridden"; fails=1; }

# verify passes the script and deny list as arguments: files in the sandbox's /tmp are the agent's to swap.
sh -n "$ROOT/libexec/verify-inside.sh" || { echo "FAIL: verify-inside.sh syntax"; fails=1; }
# Kit startup commands run as root: absolute /bin/sh (root's PATH starts with agent dirs) and valid sh.
for spec in "$ROOT"/kits/*/spec.yaml; do
  command -v yq >/dev/null || break
  n="$(yq -r '(.setup.startup // []) | length' "$spec")"
  for ((i = 0; i < n; i++)); do
    [[ "$(yq -r ".setup.startup[$i].command[0]" "$spec")" == /bin/sh ]] || { echo "FAIL: $spec startup $i: not /bin/sh"; fails=1; }
    yq -r ".setup.startup[$i].command[2]" "$spec" | sh -n || { echo "FAIL: $spec startup $i syntax"; fails=1; }
  done
done
: > "$TMP/log"; out="$("$ROOT/bin/tartarus" verify box 2>&1 || true)"
[[ "$out" == *"from the sandbox: ?]0;t?"* ]] || { echo "FAIL: verify output not sanitized"; printf '%q\n' "$out"; fails=1; }
grep -q '^sbx cp' "$TMP/log" && { echo "FAIL: verify copied files into the sandbox"; fails=1; }
grep -qF 'verify-inside mcp-proxy.anthropic.com' "$TMP/log" || { echo "FAIL: verify did not pass the deny list"; fails=1; }
grep -qE '^registry\.npmjs\.org( |$)' "$TMP/log" && { echo "FAIL: verify requires registries blocked"; fails=1; }

# review: a local repo stands in for the sandbox's git remote.
(
  set -e; cd "$TMP"; export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q -b main host && git -C host commit -q --allow-empty -m init
  git clone -q host agent && cd agent
  git checkout -q -b safe && echo hi > README.md && git add -A && git commit -q -m safe
  git checkout -q -b risky && mkdir -p .github/workflows src && touch .github/workflows/ci.yml src/package.json yarn.lock CLAUDE.md docs.md && git add -A && git commit -q -m risky
  mkdir -p gradle/wrapper infra lib docs && touch rust-toolchain.toml Directory.Build.props gradle/wrapper/gradle-wrapper.properties \
    infra/main.tf .devcontainer.json CLAUDE.local.md mise.local.toml .env.local .pylintrc src/environment.ts src/props.md \
    gradle/wrapper/gradle-wrapper.jar lib/fast.so docs/CODEOWNERS renovate.json
  git add -A && git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",vendor/dep && git commit -q -m more
  git checkout -q -b sneaky safe && mkdir -p .VSCode .vscode src/workspace && touch .VSCode/tasks.json .vscode/tâsks.json eslint.config.mjs src/workspace/a.ts
  ln -s ~/.bashrc notes && git add -A && git commit -q -m sneaky
  # A tag named main at the risky commit would make the review diff risky against itself.
  git tag main risky && git tag sandbox-box/risky safe
  # An orphan branch shares no history with the host: review must still see every file.
  git checkout -q --orphan orphan && git rm -rq --cached . && mkdir -p .github/workflows && touch .github/workflows/o.yml \
    && git add .github && git commit -q -m orphan && git clean -fdq
  git checkout -q -b escapes safe && touch "$(printf 'x\033[2K.mk')" && git add -A && git commit -q -m "$(printf 'a\033]0;t\007\302\233b')"
  cd ../host && git remote add sandbox-box ../agent
  # A second sandbox whose git server sends a tree with a .git entry.
  git init -q ../bad && cd ../bad && git commit -q --allow-empty -m init
  git branch dotgit "$(git commit-tree "$(printf '100644 blob %s\t.git\n' "$(echo x | git hash-object -w --stdin)" | git mktree)" -m dotgit)"
  cd ../host && git remote add sandbox-bad ../bad
) >/dev/null
review() { (cd "$TMP/host" && "$ROOT/bin/tartarus" review box "$1" 2>&1); }
rc=0; out="$(cd "$TMP/host" && "$ROOT/bin/tartarus" review bad dotgit 2>&1)" || rc=$?
[[ $rc != 0 && "$out" == *hasDotgit* && -z "$(git -C "$TMP/host" for-each-ref refs/remotes/sandbox-bad)" ]] \
  || { echo "FAIL: review fetched a malformed object (exit $rc)"; echo "$out"; fails=1; }
git -C "$TMP/host" fetch -q sandbox-bad 2>/dev/null && { echo "FAIL: a later fetch took the malformed object"; fails=1; }
out="$(review safe)" || { echo "FAIL: review safe exited $?"; fails=1; }
[[ "$out" == *"git branch <name> $(git -C "$TMP/agent" rev-parse safe)"* ]] || { echo "FAIL: review did not print the reviewed commit"; fails=1; }
rc=0; out="$(review risky)" || rc=$?
if [[ $rc != 2 || "$out" != *".github/workflows/ci.yml"* || "$out" != *"src/package.json"* || "$out" != *"  yarn.lock"* || "$out" != *"  CLAUDE.md"* || "${out#*REVIEW BEFORE}" == *docs.md* || "${out#*REVIEW BEFORE}" == *README* ]]; then
  echo "FAIL: review risky (exit $rc)"; echo "$out"; fails=1
fi
for f in rust-toolchain.toml Directory.Build.props gradle/wrapper/gradle-wrapper.properties infra/main.tf .devcontainer.json \
  CLAUDE.local.md mise.local.toml .env.local .pylintrc gradle/wrapper/gradle-wrapper.jar "vendor/dep (submodule)" docs/CODEOWNERS renovate.json; do
  [[ "$out" == *"  $f"* ]] || { echo "FAIL: review missed $f"; fails=1; }
done
[[ "${out#*REVIEW BEFORE}" != *environment.ts* && "${out#*REVIEW BEFORE}" != *props.md* ]] || { echo "FAIL: review flagged plain source"; fails=1; }
cmd="$(sed -n 's/^See just those changes: //p' <<<"$out")"
[[ "$(cd "$TMP/host" && eval "$cmd" | grep -c '^diff --git')" -ge 15 ]] || { echo "FAIL: review's diff command: $cmd"; fails=1; }
rc=0; out="$(review sneaky)" || rc=$?
if [[ $rc != 2 || "$out" != *".VSCode/tasks.json"* || "$out" != *".vscode/tâsks.json"* || "$out" != *"eslint.config.mjs"* \
  || "$out" != *"notes (symlink)"* || "${out#*REVIEW BEFORE}" == *workspace* ]]; then
  echo "FAIL: review sneaky (exit $rc)"; echo "$out"; fails=1
fi
git -C "$TMP/host" fetch -q sandbox-box
[[ -z "$(git -C "$TMP/host" tag)" ]] || { echo "FAIL: review or a later fetch took the agent's tags"; fails=1; }
rc=0; out="$(review orphan)" || rc=$?
[[ $rc == 2 && "$out" == *".github/workflows/o.yml"* ]] || { echo "FAIL: review of an orphan branch (exit $rc)"; echo "$out"; fails=1; }
rc=0; out="$(review nobranch)" || rc=$?
[[ $rc == 1 && "$out" == *"it has:"*"  risky"* ]] || { echo "FAIL: review of a missing branch (exit $rc)"; echo "$out"; fails=1; }
# From another directory, review finds the sandbox's repo through sbx's record of its workspace.
echo "[{\"name\": \"box\", \"workspaces\": [\"$TMP/host\"]}]" > "$TMP/state/ls.json"
rc=0; out="$(cd "$TMP" && "$ROOT/bin/tartarus" review box safe 2>&1)" || rc=$?
[[ $rc == 0 && "$out" == *"reviewing in $TMP/host"* ]] || { echo "FAIL: review from elsewhere (exit $rc)"; echo "$out"; fails=1; }
rm "$TMP/state/ls.json"
rc=0; out="$(cd "$TMP/host" && "$ROOT/bin/tartarus" review nobox x 2>&1)" || rc=$?
[[ $rc == 1 && "$out" == *"no git remote sandbox-nobox"* ]] || { echo "FAIL: review of a missing sandbox (exit $rc)"; echo "$out"; fails=1; }
rc=0; out="$(review escapes)" || rc=$?
if [[ $rc != 2 || "$out" == *$'\033'* || "$out" == *$'\007'* || "$out" == *$'\302\233'* || "$out" != *"x?[2K.mk"* ]]; then
  echo "FAIL: review escapes (exit $rc)"; printf '%q\n' "$out"; fails=1
fi

# The committed policy must be signed by the committed key (an unsigned edit would ship refused).
for f in "$ROOT"/policy/*.txt; do
  openssl dgst -sha256 -verify "$ROOT/kits/signing.pub" -signature "$f.sig" "$f" >/dev/null 2>&1 \
    || { echo "FAIL: $f is not signed by kits/signing.pub (tartarus sign-kits)"; fails=1; }
done
for k in "$ROOT"/kits/*/; do [[ -s "$k/kit.sig.bundle" ]] || { echo "FAIL: $k has no kit.sig.bundle"; fails=1; }; done
[[ "$(git -C "$ROOT" config --local -l 2>/dev/null || true)" == "$own_config" ]] || { echo "FAIL: the tests changed this repo's git config"; fails=1; }
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "$ROOT/bin/tartarus" "$ROOT/libexec/verify-inside.sh" "$ROOT/test/tartarus_test.sh" "$ROOT/test/live_test.sh" || { echo "FAIL: shellcheck"; fails=1; }
fi

((fails)) && exit 1
echo "all tests passed"
