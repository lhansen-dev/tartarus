# Tartarus

Run AI coding agents (GitHub Copilot CLI, Claude Code, Codex) inside hardened Docker Sandboxes (`sbx`): deny-all network, no host secrets, no route to production. Agents propose changes; humans review and push them.

For the why, threat model and lockdown details, see [PROPOSAL.md](PROPOSAL.md).

## Install

Requires `sbx` (signed in with `sbx login`), `git`, `python3`, and `openssl` for `sign-kits`. `yq` (either flavour) is optional, for `tartarus config` and the tests.

```sh
# macOS: brew install docker/tap/sbx    Ubuntu: sudo apt-get install docker-sbx
ln -s "$PWD/bin/tartarus" ~/.local/bin/tartarus
tartarus setup    # harden sbx on this machine; restarts the sbx daemon, stopping running sandboxes
tartarus audit    # check the machine still matches setup
```

## Use

```sh
tartarus login claude                    # credential stays in the host keychain (claude, codex, copilot)

cd ~/Dev/my-repo
tartarus run claude --name feat1         # agent works on a private clone; host repo is read-only
tartarus run claude . ../shared-lib      # extra paths mount read-only; add :rw to make one writable
tartarus verify feat1                    # audit plus in-sandbox lockdown checks

tartarus review feat1 <branch>           # fetch the agent's branch without checking it out;
                                         # exits 2 if it touched hooks, CI, IDE tasks or build files
git branch my-feature sandbox-feat1/<branch>
tartarus rm feat1
```

`tartarus safe <harness>` runs the agent on the host in a scrubbed environment when `sbx` isn't available. It is much weaker isolation.

## Configure

`tartarus config` shows every setting, its current value, and where to change it.

| Setting | Where | Then |
|---|---|---|
| Domains sandboxes may reach | `kits/team-baseline/spec.yaml` (`permissions.network.allow`) | `tartarus sign-kits`, commit |
| Prod hosts to block | `policy/deny.txt` | `tartarus setup` |
| Per-harness blocked hosts | `policy/deny-<harness>.txt` | next `run` |
| Pinned sbx settings | `SETTINGS` in `bin/tartarus` | `tartarus setup` |
| CPUs / memory | `TARTARUS_CPUS` (4) / `TARTARUS_MEMORY` (8g) | next `run` |
| Keep sudo and Docker for the agent | `TARTARUS_ALLOW_ROOT=1` | next `run` |
| Alternate kit, deny file, kit sources, signing key | `TARTARUS_BASELINE_KIT`, `TARTARUS_DENY_FILE`, `TARTARUS_KIT_SOURCES`, `TARTARUS_SIGNING_KEY` | |

Kits are signed: `sbx` refuses a kit changed without re-signing. A changed `kits/signing.pub` takes effect only after everyone re-runs `tartarus setup`.

## Test

```sh
bash test/tartarus_test.sh    # uses a stub sbx; no sandboxes are created
```
