#!/usr/bin/env bash
# Checks the sbx commands tartarus builds, using a stub sbx that logs its argv.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\necho "sbx $*" >> "%s/log"\n' "$TMP" > "$TMP/sbx"
chmod +x "$TMP/sbx"
export PATH="$TMP:$PATH" TARTARUS_BASELINE_KIT=KIT

fails=0
check() { # check "<tartarus args>" "<expected last sbx line>"
  : > "$TMP/log"
  eval "$ROOT/bin/tartarus $1" >/dev/null 2>&1 || true
  local got; got="$(tail -n1 "$TMP/log")"
  if [[ "$got" != "$2" ]]; then echo "FAIL: tartarus $1"; echo "  want: $2"; echo "  got:  $got"; fails=1; fi
}

R="run --clone --skills off --cpus 4 --memory 8g --kit KIT"
check "run claude" "sbx $R claude ."
check "run codex --name x --detach ~/a ~/b ~/c:ro ~/d:rw -- -m o3" \
  "sbx $R --name x --detach codex $HOME/a $HOME/b:ro $HOME/c:ro $HOME/d -- -m o3"
check "run copilot" "sbx $R --kit docker.io/sbx/copilot-kit:latest copilot ."
check "run gemini" ""
check "run claude ~/a/repo ~/a" ""        # extra contains the repo: refused
check "run claude ~/a ~/a/sub:rw" ""      # extra inside the repo: refused
check "run claude ~/a ~/ab" "sbx $R claude $HOME/a $HOME/ab:ro"  # prefix-named sibling is fine
check "login codex" "sbx secret set openai --oauth"
check "login copilot" "sbx secret set copilot"
check "setup" "sbx policy deny network *.prod.yourco.com"

: > "$TMP/log"; "$ROOT/bin/tartarus" setup >/dev/null
for want in "sbx settings set ssh.agentForwardingEnabled false" "sbx settings set clipboard.imagePaste false" \
  "sbx settings set skills.defaultMode off" "sbx policy reset --force" "sbx policy init deny-all"; do
  grep -qxF "$want" "$TMP/log" || { echo "FAIL: setup missing: $want"; fails=1; }
done

((fails)) && exit 1
echo "all tests passed"
