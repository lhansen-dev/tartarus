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

  # The lockdown mustn't break the agent: a small task with a tool call (uses the model credential).
  task='Create hello.txt containing hi using a tool, then reply DONE'
  case "$h" in
    claude) agent=(env CLAUDE_CODE_TMPDIR=/home/agent/tmp claude -p --dangerously-skip-permissions "$task") ;;
    codex) agent=(codex exec --skip-git-repo-check "$task") ;;
    *) agent=() ;;
  esac
  if ((${#agent[@]})); then
    sbx exec "$box" sh -c 'mkdir -p ~/tmp ~/live && cd ~/live && "$@" >/dev/null 2>&1; grep -qx hi hello.txt' sh "${agent[@]}" \
      && ok "agent completes a tool task" || bad "agent couldn't complete a tool task (logged in? tartarus login $h)"
  fi

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

  # A branch with no shared history must still be reviewed file by file.
  sbx exec -w "$TMP/repo" "$box" sh -c 'git checkout -q --orphan orphan && git rm -rqf --cached . >/dev/null; mkdir -p .github/workflows &&
    touch .github/workflows/o.yml && git add .github && git -c user.name=a -c user.email=a@a commit -qm orphan' >/dev/null 2>&1 || bad "agent orphan commit"
  rc=0; "$T" review "$box" orphan >"$TMP/review" 2>&1 || rc=$?
  [[ $rc == 2 ]] && grep -q 'o.yml' "$TMP/review" && ok "review flags an orphan branch" || bad "orphan review (exit $rc)"

  # Drift audit must catch: a lost harness deny, and a kit added after creation.
  deny="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ROOT/policy/deny-$h.txt" | grep -v '^$' | head -1)"
  if [[ -n "$deny" ]]; then
    sbx policy rm network --sandbox "$box" --resource "$deny" --force >/dev/null 2>&1
    "$T" audit >/dev/null 2>&1 && bad "audit missed a removed deny ($deny)" || ok "audit catches a removed deny"
    sbx policy deny network --sandbox "$box" "$deny" >/dev/null 2>&1
  fi
  mkdir -p "$TMP/sneak"; sbx mount "$box" "$TMP/sneak" >/dev/null 2>&1 || bad "sbx mount"
  "$T" verify "$box" >/dev/null 2>&1 && bad "verify missed a host path added with sbx mount" || ok "verify catches sbx mount"
  sbx kit add "$box" "$ROOT/kits/registries" >/dev/null 2>&1 || bad "kit add"
  "$T" audit >/dev/null 2>&1 && bad "audit missed an added kit" || ok "audit catches a kit added later"

  "$T" rm "$box" >/dev/null 2>&1 || bad "rm"
  [[ -z "$(git for-each-ref "refs/sandboxes/$box" "refs/remotes/sandbox-$box")" ]] && ok "rm left no refs" || bad "rm left refs"
done

"$T" audit >/dev/null 2>&1 && ok "audit passes again once they're gone" || bad "audit still fails after rm"
((fails)) && { echo "live: FAIL"; exit 1; }
echo "live: all checks passed"
