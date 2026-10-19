#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok/bad only echo, so A && B || C is safe here
# Live checks against the real sbx on this machine: makes throwaway sandboxes (tt-live-*), attacks
# them the way a hijacked agent would, and removes them. Needs tartarus setup done (audit passing)
# and harness logins. Takes a few minutes. Run: bash test/live_test.sh [claude codex copilot]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$ROOT/bin/tartarus"
harnesses=("${@:-claude codex}")
read -ra harnesses <<<"${harnesses[*]}"
TMP="$(mktemp -d)"
cleanup() { for h in "${harnesses[@]}"; do (cd "$TMP/repo" && "$T" rm "tt-live-$h" >/dev/null 2>&1) || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=1; }
# expect_fail <description> <sandbox> <shell command run as the agent>: the attack must not work.
expect_fail() { if sbx exec "$2" sh -c "$3" >/dev/null 2>&1; then bad "$1 worked"; else ok "$1 refused"; fi; }

"$T" audit >/dev/null || { echo "tartarus audit fails on this machine; run tartarus setup first"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" commit -q --allow-empty -m init
cd "$TMP/repo"

for h in "${harnesses[@]}"; do
  box="tt-live-$h"
  echo "$h"
  "$T" run "$h" --name "$box" --detach >/dev/null 2>&1 && ok "sandbox created" || { bad "run $h"; continue; }
  "$T" verify "$box" >"$TMP/verify" 2>&1 && ok "verify passes" || { bad "verify:"; grep FAIL "$TMP/verify"; }

  # No root, and no way to get it on the next start.
  expect_fail "sudo" "$box" 'sudo -n true'
  expect_fail "a command planted on root's PATH" "$box" 'printf "#!/bin/sh\n" > ~/.local/bin/mkdir'
  expect_fail "swapping ~/.local for a fresh one" "$box" 'mv ~/.local ~/.local-old'
  expect_fail "writing root's BASH_ENV file" "$box" 'echo id >> /etc/sandbox-persistent.sh'
  expect_fail "using the Docker socket" "$box" 'test -w /var/run/docker.sock && docker ps'
  # The host repo is read-only, and the network goes nowhere but the model API.
  expect_fail "writing the host repo" "$box" 'touch /run/sandbox/source/x'
  expect_fail "reaching example.com" "$box" 'curl -sf -m 8 -o /dev/null https://example.com'
  # Refused with or without TARTARUS_REGISTRIES=1: registries are read-only.
  expect_fail "a write to npm (publish)" "$box" 'curl -sf -m 8 -o /dev/null -X PUT -d {} https://registry.npmjs.org/tartarus-live'
  expect_fail "direct DNS" "$box" 'python3 -I -c "import socket; s=socket.socket(2,2); s.settimeout(4); s.sendto(b\"x\"*12, (\"8.8.8.8\", 53)); s.recv(9)"'

  # The trust handoff: an agent commit with CI changes and a tag named main.
  sbx exec -w "$TMP/repo" "$box" sh -c 'git checkout -q -b live && mkdir -p .github/workflows && touch .github/workflows/x.yml &&
    git add -A && git -c user.name=a -c user.email=a@a commit -qm live && git tag main' >/dev/null 2>&1 || bad "agent commit"
  git fetch -q --all 2>/dev/null || true
  [[ -z "$(git tag)" ]] && ok "no agent tags in the host repo" || bad "agent tags reached the host repo: $(git tag | tr '\n' ' ')"
  rc=0; "$T" review "$box" live >"$TMP/review" 2>&1 || rc=$?
  [[ $rc == 2 ]] && grep -q '.github/workflows/x.yml' "$TMP/review" && ok "review flags the CI change" || bad "review (exit $rc)"

  "$T" rm "$box" >/dev/null 2>&1 || bad "rm"
  [[ -z "$(git for-each-ref "refs/sandboxes/$box" "refs/remotes/sandbox-$box")" ]] && ok "rm left no refs" || bad "rm left refs"
done

((fails)) && { echo "live: FAIL"; exit 1; }
echo "live: all checks passed"
