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

check "run claude" "sbx run --clone --kit KIT claude ."
check "run codex --name x ~/a ~/b:ro -- -m o3" "sbx run --clone --kit KIT --name x codex $HOME/a $HOME/b:ro -- -m o3"
check "run copilot" "sbx run --clone --kit KIT --kit docker.io/sbx/copilot-kit:latest copilot ."
check "run gemini" ""
check "login codex" "sbx secret set openai --oauth"
check "login copilot" "sbx secret set copilot"
check "setup" "sbx policy deny network *.prod.yourco.com"

((fails)) && exit 1
echo "all tests passed"
