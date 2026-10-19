# Tartarus

Run AI coding agents (GitHub Copilot CLI, Claude Code, Codex) inside hardened Docker Sandboxes (`sbx`): deny-all network, no host secrets, no route to production. Agents propose changes; humans review and push them.

For the why, threat model and lockdown details, see [PROPOSAL.md](PROPOSAL.md).

## Install

Requires `sbx` (signed in with `sbx login`), bash 4.4 or later (macOS ships 3.2: `brew install bash`), `git`, `python3` and `openssl`. `yq` (either flavour) is optional, for `tartarus config` and the tests.

```sh
# macOS: brew install docker/tap/sbx    Ubuntu: sudo apt-get install docker-sbx
ln -s "$PWD/bin/tartarus" ~/.local/bin/tartarus
tartarus setup    # harden sbx on this machine; restarts the sbx daemon, stopping running sandboxes
tartarus audit    # check the machine still matches setup (run does this too, and refuses to start if it fails)
```

## Use

```sh
tartarus login claude                    # credential stays in the host keychain (claude, codex, copilot)

cd ~/Dev/my-repo
tartarus run claude --name feat1         # agent works on a private clone; host repo is read-only
tartarus run claude . ../shared-lib      # extra paths mount read-only; add :rw to make one writable
                                         # refuses paths with untracked .env/keys or tokens in .git/config
TARTARUS_REGISTRIES=1 tartarus run claude  # also allow npm and PyPI for this sandbox
tartarus verify feat1                    # audit plus in-sandbox lockdown checks

tartarus review feat1 <branch>           # fetch the agent's branch without checking it out;
                                         # exits 2 if it touched hooks, CI, IDE tasks or build files
git branch my-feature <commit review printed>  # not the branch: it moves on the next fetch
tartarus rm feat1                        # also dismisses its pending approval prompts
tartarus dismiss                         # dismiss every pending prompt; never allow one
tartarus ls                              # which sandboxes predate the current lockdown: rm those
```

A sandbox keeps the config it was created with. Change tartarus, a kit, the policy, or a run's paths, and the next `run` makes a new sandbox; with `--name`, it refuses until you `tartarus rm` the old one.

`tartarus safe <harness>` runs the agent on the host in a scrubbed environment, inside the harness's own sandbox (Claude's needs `bubblewrap` and `socat` on Linux, and refuses to start without them), when `sbx` isn't available. It is much weaker isolation.

## Configure

`tartarus config` shows every setting, its current value, and where to change it.

| Setting | Where | Then |
|---|---|---|
| Domains sandboxes may reach (none by default) | `kits/team-baseline/spec.yaml` (`permissions.network.allow`) | `tartarus sign-kits`, commit |
| Allow npm and PyPI for a run | `TARTARUS_REGISTRIES=1` (`kits/registries`) | next `run` |
| Prod hosts to block | `policy/deny.txt` | `tartarus sign-kits`, commit, `tartarus setup` |
| Per-harness blocked hosts | `policy/deny-<harness>.txt` | `tartarus sign-kits`, commit |
| Pinned sbx settings | `SETTINGS` in `bin/tartarus` | `tartarus setup` |
| CPUs / memory | `TARTARUS_CPUS` (4) / `TARTARUS_MEMORY` (8g) | next `run` |
| Keep root for the agent: sudo, Docker, writable `~/.local/bin` (`pip install --user`, `npm -g`) | `TARTARUS_ALLOW_ROOT=1` | next `run` |
| Mount paths holding `.env`, keys and similar untracked files | `TARTARUS_ALLOW_SECRET_FILES=1` | next `run` |
| Copilot kit version (pinned by digest) | `COPILOT_KIT` in `bin/tartarus` | verify the new digest first (see the comment there) |
| Alternate kit, deny file, kit sources, signing key | `TARTARUS_BASELINE_KIT`, `TARTARUS_DENY_FILE`, `TARTARUS_KIT_SOURCES`, `TARTARUS_SIGNING_KEY` | |

Kits and policy files are signed: an edited, unsigned or missing one is refused by `sbx`, `setup`, `run` and `audit` until it's re-signed. A changed or deleted `kits/signing.pub` is refused by `setup` until you re-run it with `TARTARUS_REPIN=1`.

## What it does and doesn't protect

It keeps the agent away from your host, your secrets and prod: no network beyond the model API, no host credentials, no writes to your repo. It does not check the code the agent writes. `tartarus review` flags files that run on their own, but once you test or run the branch on the host, every changed file runs. Read the whole diff first. See PROPOSAL.md's "Risks and limitations" for the full list.

## Test

```sh
bash test/tartarus_test.sh    # uses a stub sbx; no sandboxes are created. Runs shellcheck if installed
tartarus verify <sandbox>     # the live check: run it on a real sandbox after changing a kit or policy
bash test/live_test.sh        # real sandboxes, attacked like a hijacked agent would (needs setup and logins)
```
