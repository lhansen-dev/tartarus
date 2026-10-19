#!/usr/bin/env bash
# Checks the sbx commands tartarus builds, using a stub sbx that logs its argv.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\necho "sbx $*" >> "%s/log"\ncase "$*" in "settings get kit.trustedSigners") echo "[]" ;; esac\n' "$TMP" > "$TMP/sbx"
chmod +x "$TMP/sbx"
export PATH="$TMP:$PATH" TARTARUS_BASELINE_KIT=KIT XDG_CONFIG_HOME="$TMP/config"

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
DX="--deny-network github.com --deny-network api.github.com --deny-network codeload.github.com"
check "run claude" "sbx $R $DC claude ."
check "run codex --name x --detach ~/a ~/b ~/c:ro ~/d:rw -- -m o3" \
  "sbx $R $DX --name x --detach codex $HOME/a $HOME/b:ro $HOME/c:ro $HOME/d -- -m o3"
check "run copilot" "sbx $R --kit docker.io/sbx/copilot-kit:latest copilot ."
check "run gemini" ""
check "run claude ~/a/repo ~/a" ""        # extra contains the repo: refused
check "run claude ~/a ~/a/sub:rw" ""      # extra inside the repo: refused
check "run claude ~/a ~/ab" "sbx $R $DC claude $HOME/a $HOME/ab:ro"  # prefix-named sibling is fine
check "run claude --kit evil ." ""        # unknown option: refused, not passed to sbx as a path
check "run claude ~/a ~/.ssh" ""          # home dotdir: refused
check "run claude /srv/a $HOME" ""        # all of home: refused
check "rm a b" "sbx rm --force b"
check "login codex" "sbx secret set openai --oauth"
check "login copilot" "sbx secret set copilot"
check "setup" "sbx daemon restart"

: > "$TMP/log"; "$ROOT/bin/tartarus" setup >/dev/null
for want in "sbx settings set ssh.agentForwardingEnabled false" "sbx settings set clipboard.imagePaste false" \
  "sbx settings set skills.defaultMode off" "sbx policy reset --force" "sbx policy init deny-all" \
  "sbx policy deny network *.prod.yourco.com" "sbx settings set kit.requireSignature true" "sbx daemon restart"; do
  grep -qxF "$want" "$TMP/log" || { echo "FAIL: setup missing: $want"; fails=1; }
done
grep -qF "sbx settings set kit.trustedSigners [{\"key\": \"$TMP/config/tartarus/kit-signing.pub\"}]" "$TMP/log" \
  || { echo "FAIL: setup did not trust the pinned key"; fails=1; }

out="$(TARTARUS_CPUS=2 TARTARUS_BASELINE_KIT="$ROOT/kits/team-baseline" "$ROOT/bin/tartarus" config)"
[[ "$out" == *"allow       registry.npmjs.org, pypi.org, files.pythonhosted.org"* && "$out" == *"Deny (codex)  github.com,"* \
  && "$out" == *"cpus=2 memory=8g"* ]] || { echo "FAIL: config"; echo "$out"; fails=1; }

# Default names carry a lockdown fingerprint: stable for the same config, new when it changes.
name_of() { : > "$TMP/log"; env "$@" "$ROOT/bin/tartarus" run claude ~/repo >/dev/null 2>&1 || true
  grep -oE -- '--name tartarus-claude-repo-[0-9]+' "$TMP/log"; }
n1="$(name_of X=1)"; n2="$(name_of X=1)"; n3="$(name_of TARTARUS_CPUS=2)"
[[ -n "$n1" && "$n1" == "$n2" && "$n1" != "$n3" ]] || { echo "FAIL: fingerprint names: '$n1' '$n2' '$n3'"; fails=1; }
: > "$TMP/log"; "$ROOT/bin/tartarus" run claude --name mine . >/dev/null 2>&1 || true
[[ "$(grep -o -- '--name [^ ]*' "$TMP/log")" == "--name mine" ]] || { echo "FAIL: explicit --name overridden"; fails=1; }

# review: a local repo stands in for the sandbox's git remote.
(
  set -e; cd "$TMP"; export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q -b main host && git -C host commit -q --allow-empty -m init
  git clone -q host agent && cd agent
  git checkout -q -b safe && echo hi > README.md && git add -A && git commit -q -m safe
  git checkout -q -b risky && mkdir -p .github/workflows src && touch .github/workflows/ci.yml src/package.json CLAUDE.md docs.md && git add -A && git commit -q -m risky
  git checkout -q -b sneaky safe && mkdir -p .VSCode .vscode src/workspace && touch .VSCode/tasks.json .vscode/tâsks.json eslint.config.mjs src/workspace/a.ts
  ln -s ~/.bashrc notes && git add -A && git commit -q -m sneaky
  cd ../host && git remote add sandbox-box ../agent
) >/dev/null
review() { (cd "$TMP/host" && "$ROOT/bin/tartarus" review box "$1" 2>&1); }
out="$(review safe)" || { echo "FAIL: review safe exited $?"; fails=1; }
rc=0; out="$(review risky)" || rc=$?
if [[ $rc != 2 || "$out" != *".github/workflows/ci.yml"* || "$out" != *"src/package.json"* || "$out" != *"  CLAUDE.md"* || "${out#*REVIEW BEFORE}" == *docs.md* || "${out#*REVIEW BEFORE}" == *README* ]]; then
  echo "FAIL: review risky (exit $rc)"; echo "$out"; fails=1
fi
rc=0; out="$(review sneaky)" || rc=$?
if [[ $rc != 2 || "$out" != *".VSCode/tasks.json"* || "$out" != *".vscode/tâsks.json"* || "$out" != *"eslint.config.mjs"* \
  || "$out" != *"notes (symlink)"* || "${out#*REVIEW BEFORE}" == *workspace* ]]; then
  echo "FAIL: review sneaky (exit $rc)"; echo "$out"; fails=1
fi

((fails)) && exit 1
echo "all tests passed"
