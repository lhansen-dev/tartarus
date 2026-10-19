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
export TARTARUS_REGISTRIES=1; check "run claude" "sbx $R --kit $ROOT/kits/registries $DC claude ."; unset TARTARUS_REGISTRIES
check "run gemini" ""
check "run claude ~/a/repo ~/a" ""        # extra contains the repo: refused
check "run claude ~/a ~/a/sub:rw" ""      # extra inside the repo: refused
check "run claude ~/a ~/ab" "sbx $R $DC claude $HOME/a $HOME/ab:ro"  # prefix-named sibling is fine
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

# Default names carry a lockdown fingerprint: stable for the same config, new when it changes.
name_of() { : > "$TMP/log"; env "$@" "$ROOT/bin/tartarus" run claude ~/repo >/dev/null 2>&1 || true
  grep -oE -- '--name tartarus-claude-repo-[0-9]+' "$TMP/log"; }
n1="$(name_of X=1)"; n2="$(name_of X=1)"; n3="$(name_of TARTARUS_CPUS=2)"
[[ -n "$n1" && "$n1" == "$n2" && "$n1" != "$n3" ]] || { echo "FAIL: fingerprint names: '$n1' '$n2' '$n3'"; fails=1; }
: > "$TMP/log"; "$ROOT/bin/tartarus" run claude "$TMP/my_repo (2)" >/dev/null 2>&1 || true
grep -qE -- '--name tartarus-claude-my-repo--2--[0-9]+ ' "$TMP/log" || { echo "FAIL: name not sanitized: $(cat "$TMP/log")"; fails=1; }
: > "$TMP/log"; "$ROOT/bin/tartarus" run claude --name mine . >/dev/null 2>&1 || true
[[ "$(grep -o -- '--name [^ ]*' "$TMP/log")" == "--name mine" ]] || { echo "FAIL: explicit --name overridden"; fails=1; }

# verify passes the script and deny list as arguments: files in the sandbox's /tmp are the agent's to swap.
sh -n "$ROOT/libexec/verify-inside.sh" || { echo "FAIL: verify-inside.sh syntax"; fails=1; }
: > "$TMP/log"; "$ROOT/bin/tartarus" verify box >/dev/null 2>&1 || true
grep -q '^sbx cp' "$TMP/log" && { echo "FAIL: verify copied files into the sandbox"; fails=1; }
grep -qF 'verify-inside mcp-proxy.anthropic.com' "$TMP/log" || { echo "FAIL: verify did not pass the deny list"; fails=1; }

# review: a local repo stands in for the sandbox's git remote.
(
  set -e; cd "$TMP"; export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q -b main host && git -C host commit -q --allow-empty -m init
  git clone -q host agent && cd agent
  git checkout -q -b safe && echo hi > README.md && git add -A && git commit -q -m safe
  git checkout -q -b risky && mkdir -p .github/workflows src && touch .github/workflows/ci.yml src/package.json yarn.lock CLAUDE.md docs.md && git add -A && git commit -q -m risky
  mkdir -p gradle/wrapper infra && touch rust-toolchain.toml Directory.Build.props gradle/wrapper/gradle-wrapper.properties \
    infra/main.tf .devcontainer.json CLAUDE.local.md mise.local.toml .env.local .pylintrc src/environment.ts src/props.md
  git add -A && git commit -q -m more
  git checkout -q -b sneaky safe && mkdir -p .VSCode .vscode src/workspace && touch .VSCode/tasks.json .vscode/tâsks.json eslint.config.mjs src/workspace/a.ts
  ln -s ~/.bashrc notes && git add -A && git commit -q -m sneaky
  # A tag named main at the risky commit would make the review diff risky against itself.
  git tag main risky && git tag sandbox-box/risky safe
  git checkout -q -b escapes safe && touch "$(printf 'x\033[2K.mk')" && git add -A && git commit -q -m "$(printf 'a\033]0;t\007\302\233b')"
  cd ../host && git remote add sandbox-box ../agent
) >/dev/null
review() { (cd "$TMP/host" && "$ROOT/bin/tartarus" review box "$1" 2>&1); }
out="$(review safe)" || { echo "FAIL: review safe exited $?"; fails=1; }
rc=0; out="$(review risky)" || rc=$?
if [[ $rc != 2 || "$out" != *".github/workflows/ci.yml"* || "$out" != *"src/package.json"* || "$out" != *"  yarn.lock"* || "$out" != *"  CLAUDE.md"* || "${out#*REVIEW BEFORE}" == *docs.md* || "${out#*REVIEW BEFORE}" == *README* ]]; then
  echo "FAIL: review risky (exit $rc)"; echo "$out"; fails=1
fi
for f in rust-toolchain.toml Directory.Build.props gradle/wrapper/gradle-wrapper.properties infra/main.tf .devcontainer.json \
  CLAUDE.local.md mise.local.toml .env.local .pylintrc; do
  [[ "$out" == *"  $f"* ]] || { echo "FAIL: review missed $f"; fails=1; }
done
[[ "${out#*REVIEW BEFORE}" != *environment.ts* && "${out#*REVIEW BEFORE}" != *props.md* ]] || { echo "FAIL: review flagged plain source"; fails=1; }
rc=0; out="$(review sneaky)" || rc=$?
if [[ $rc != 2 || "$out" != *".VSCode/tasks.json"* || "$out" != *".vscode/tâsks.json"* || "$out" != *"eslint.config.mjs"* \
  || "$out" != *"notes (symlink)"* || "${out#*REVIEW BEFORE}" == *workspace* ]]; then
  echo "FAIL: review sneaky (exit $rc)"; echo "$out"; fails=1
fi
git -C "$TMP/host" fetch -q --all
[[ -z "$(git -C "$TMP/host" tag)" ]] || { echo "FAIL: review or a later fetch took the agent's tags"; fails=1; }
rc=0; out="$(review nobranch)" || rc=$?
[[ $rc == 1 && "$out" == *"it has:"*"  risky"* ]] || { echo "FAIL: review of a missing branch (exit $rc)"; echo "$out"; fails=1; }
rc=0; out="$(cd "$TMP/host" && "$ROOT/bin/tartarus" review nobox x 2>&1)" || rc=$?
[[ $rc == 1 && "$out" == *"no git remote sandbox-nobox"* ]] || { echo "FAIL: review of a missing sandbox (exit $rc)"; echo "$out"; fails=1; }
rc=0; out="$(review escapes)" || rc=$?
if [[ $rc != 2 || "$out" == *$'\033'* || "$out" == *$'\007'* || "$out" == *$'\302\233'* || "$out" != *"x?[2K.mk"* ]]; then
  echo "FAIL: review escapes (exit $rc)"; printf '%q\n' "$out"; fails=1
fi

((fails)) && exit 1
echo "all tests passed"
