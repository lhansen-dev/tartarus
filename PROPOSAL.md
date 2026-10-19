# Tartarus: Running AI Coding Agents in Docker Sandboxes (sbx)

2026-10-18 · Luke Hansen

> In Greek myth, Tartarus is the prison that held the Titans: powerful, and kept where they can't reach the world above. Tartarus does the same for coding agents.

## Quick start

- `tartarus setup` — harden the machine (rebuilds `sbx`'s host configuration).
- `tartarus login <harness>` — give the sandbox only the model credential.
- `tartarus run <harness>` — run the agent in a hardened sandbox.
- `tartarus verify <sandbox-name>` — run the host audit and in-sandbox lockdown checks.
- `tartarus review <sandbox-name> <branch>` — fetch, log, diffstat, and flag files that run on the host.
- `tartarus rm <sandbox-name>` — remove the sandbox and the refs `sbx` leaves behind.

## Summary

Teams should run their AI coding agents inside Docker Sandboxes (`sbx`) by default, for every session, whether interactive or fully autonomous. The agent then has no route or credentials to production. Tartarus is harness-agnostic: one command, one kit and one policy cover GitHub Copilot CLI, Claude Code and Codex. This is an opt-in team pattern, not a mandate, and it keeps autopilot fully available.

One default instead of several options keeps the pattern easy to teach and easy to follow. It comes with one rule: agents propose production changes, and humans execute them.

## Problem

Everyone has agent autopilot (Copilot autopilot, Claude Code's `--dangerously-skip-permissions`, Codex's full-auto modes), but nothing physically stops an agent from reaching production. An agent runs as the developer, so it inherits whatever that person's machine can reach: Vault tokens, 1Password-injected env vars, kube contexts, cloud credentials, and the corporate network.

Each harness ships its own local sandbox, and each draws the line differently. GHCP's wraps the commands Copilot runs rather than the agent itself [1]. By default it passes Git and GitHub credentials into sandboxed commands [1], grants access to developer-tool configs such as `~/.npmrc` [2], and lets Copilot ask to run a single command outside the sandbox [1]. Built-in sandboxes are fine for everyday work, but too permissive for letting agents run freely and unattended, and three different models are three things to teach and audit.

We want agents to move fast without anyone worrying about a prod incident, and we don't want to solve that by taking autopilot away.

## Proposal: sbx by default, for any harness

Every agent session runs in `sbx`, whatever the task and whatever the harness. The rule behind it: an agent can't break what it can't reach.

- **Interactive work:** `tartarus run <harness>` (see Team setup), used like a normal session.
- **Autonomous work:** the same command. Each harness starts in its full-autonomy mode inside the sandbox. No extra setup.
- **Production:** agents never touch it. The agent writes the PR, the migration, the runbook, or the exact command; a human reviews it and runs it with their own short-lived credentials. This matches the industry default of unrestricted agent access to non-prod environments and propose-only access to production [3].

### Supported harnesses

`sbx` supports all three as first-class agents; Tartarus only chooses the credential and kit for each.

| Harness | `sbx` agent | Starts as (inside the VM) | Credential, held on the host | Extra kit |
|---|---|---|---|---|
| GitHub Copilot CLI | `copilot` | `copilot --yolo` [20] | `copilot` secret only (Copilot API) [21] | `docker.io/sbx/copilot-kit` [21] |
| Claude Code | `claude` | `claude --dangerously-skip-permissions` [28] | `/login` OAuth inside the sandbox, or `anthropic` API key [22] | none |
| Codex | `codex` | `codex --dangerously-bypass-approvals-and-sandbox` [29] | `openai` via `--oauth` on the host [22] | none |

Adding another `sbx`-supported harness (Gemini, Cursor, OpenCode and others [30]) takes one `case` arm in `bin/tartarus` and a `policy/deny-<harness>.txt`.

Claude Code and Codex have been tested end to end under the full lockdown. Copilot is wired the same way but not yet tested: no Copilot account was available. Its kit allows `github.com` and `api.github.com`, so check `sbx policy log` during the pilot and add a `policy/deny-copilot.txt` for anything it doesn't need.

### VS Code

VS Code connects to a sandbox over Remote-SSH, so the editor stays on the host while files, terminals, and extensions run inside the sandbox [14]. Copilot agent mode's edits and commands, and any Claude Code or Codex extension, therefore run in the VM.

1. Run `sbx setup ssh` once (requires Docker Sandboxes 0.37.0 or later) [15].
2. Create a sandbox for the project: `sbx create --name <project> shell .`
3. In VS Code, run **Remote-SSH: Connect to Host…** and enter `<project>.sbx`, then open the mounted workspace with the remote folder picker [14].

The network policy must allow Microsoft's VS Code download domains and the harness's endpoints, because the first connection installs the VS Code server inside the sandbox [14]. Under Tartarus's `deny-all` policy, that means adding those domains to the baseline kit; this path hasn't been tested yet. On macOS, if VS Code loops on reconnect, set `remote.SSH.useLocalServer` to `false` [14].

- [ ] Confirm our macOS Tahoe 26+ requirement covers every developer Mac, since `sbx` needs it [10].

## Why sbx

`sbx` puts the whole agent in a separate microVM with its own kernel, Docker daemon, filesystem, and network [4], [5]. By default it can't reach the host filesystem outside the workspace, the host Docker daemon, the host network or localhost, or other sandboxes, and these can't be unblocked by policy [17]. Copilot CLI, Claude Code and Codex are all supported agents [30], so one boundary covers every harness.

`sbx`'s defaults still leave several doors open, all found and closed during testing with `sbx` v0.48.0 (see Lockdown layers):
- the host SSH agent is forwarded [22];
- the `balanced` network policy allows about 190 destinations;
- the agent has passwordless `sudo` in the VM;
- a clipboard bridge to the host is running;
- the Claude kit can reach your claude.ai connectors.

| | Harness built-in sandbox (GHCP shown) | Docker Sandboxes (`sbx`) |
|---|---|---|
| Isolation | OS-level controls via Microsoft eXecution Container [7] | Dedicated microVM per session [5] |
| What's isolated | Most commands the agent runs; the agent runs on the host [1] | Everything, including the agent |
| What the agent sees | Your real filesystem, minus the policy | Only the mounted project folder |
| Credentials | Git and GitHub credentials passed through by default [1] | Held on the host and added by a proxy; never enter the VM [8], [22] |
| Network | Configurable | Host-side proxy. Tartarus sets `deny-all`, so each sandbox reaches only its harness vendor's API plus npm and PyPI. Raw TCP, UDP and ICMP are blocked, as are private IP ranges, loopback and link-local addresses [17] |
| Escape hatch | Can request to run one command outside [1] | None built in |
| Same model for every harness | No, each harness has its own | Yes |
| Requirements | Built into the harness, free | macOS Tahoe 26+ on Macs; Docker Desktop not required [6], [10] |

In short: a harness sandbox is a fence inside your house, and `sbx` is a separate building with only your project carried in.

## Team setup

Setup is four commands per machine, plus the `tartarus` repo the team maintains in git:
- `bin/tartarus`: the launcher;
- `kits/`: the signed shared kits;
- `policy/`: prod hostnames and per-harness deny lists.

1. **Install `sbx` and sign in** [4]:
   - macOS: `brew install docker/tap/sbx`
   - Ubuntu: `sudo apt-get install docker-sbx` (after adding Docker's repo)
   - Then: `sbx login`, and put `tartarus/bin` on your `PATH`. `sbx` requires a Docker sign-in even for local sandboxes.
2. **Harden the machine:** `tartarus setup`. It rebuilds `sbx`'s host configuration from scratch, so it's safe to re-run:

   ```bash
   sbx settings set ssh.agentForwardingEnabled false   # plus clipboard, remote control, skills, SSH auto-create, diagnostics upload: see Lockdown layers
   sbx settings set kit.allowedSources '["docker.io/sbx/"]'
   sbx policy reset --force && sbx policy init deny-all
   sbx policy deny network "<each host in policy/deny.txt>"
   sbx settings set kit.trustedSigners '[<Docker>, {"key": "~/.config/tartarus/kit-signing.pub"}]'
   sbx settings set kit.requireSignature true
   sbx daemon restart                                  # ssh.* settings only apply after this
   ```

   - **SSH forwarding:** it's on by default [22], and with 1Password's SSH agent it would hand the sandbox every key we hold. If a team needs signed agent commits, run an isolated SSH agent loaded only with an agent-only key [25], or use Docker's signing kit [26].
   - **Network:** under `deny-all`, the global policy allows nothing. Each sandbox gets only its harness kit's vendor endpoints plus the baseline kit's npm and PyPI [9], [11]. Private IP ranges, loopback and link-local addresses are blocked regardless [17]. `policy/deny.txt` is for prod endpoints with public addresses, such as public APIs and cloud control planes.
   - **Kits:** only kits signed by the team key, plus Docker's own, can be installed. Kits run code inside the sandbox [8].

   `tartarus audit` checks all of this at any time, including that no extra kit signer or kit source was added since setup, and `tartarus verify` runs it automatically.
3. **Give the sandbox only the model credential:** `tartarus login <harness>`.
   - **Copilot:** stores only the `copilot` secret (`COPILOT_GITHUB_TOKEN`, injected for `*.githubcopilot.com` and `copilot.github.com`). We deliberately skip the kit's `github` secret (`GH_TOKEN`, injected for `github.com`) [21]: our code lives on our own GitHub server, and the agent shouldn't push anywhere. `audit` fails if a `github` secret is ever stored.
   - **Claude Code:** sign in with `/login` inside the sandbox (OAuth, token stays on the host), or store an API key with `sbx secret set anthropic` [22], [28].
   - **Codex:** `sbx secret set openai --oauth` signs in on the host and keeps the tokens in the OS keychain [29].

   The proxy adds the credential to matching requests. Inside the sandbox, Claude's `.credentials.json` and Codex's `auth.json` hold only placeholder values (checked by `verify`) [22].
4. **Run the agent:** `tartarus run <harness>`, which runs:

   ```bash
   sbx run --clone --skills off --cpus 4 --memory 8g \
     --kit kits/team-baseline --kit kits/no-root \
     [--kit docker.io/sbx/copilot-kit:latest]           # copilot only
     --deny-network <each host in policy/deny-<harness>.txt> \
     --name tartarus-<harness>-<repo>-<lockdown fingerprint> \
     <copilot|claude|codex> [paths...] [-- agent args]
   ```

   In clone mode the agent works on a private in-VM clone, and the host repository is mounted read-only [18]. Arguments after `--` that start with `-` are added after the harness's autonomy flags; a bare word replaces them [28], [29].

   The default name ends in a fingerprint of the launcher, kits and policies. `sbx` ignores creation flags when it re-attaches to an existing sandbox, so without the fingerprint, a hardening change would silently not apply to a sandbox you already have. With it, any such change gives you a fresh sandbox.

Sandboxes don't pick up user-level harness config such as `~/.claude` or `~/.codex`; only project-level config in the workspace is visible [28], [29]. Shared agent instructions (`CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`) therefore belong in the repo, or in the baseline kit's `files/home/`.

### Multi-repo work

Mount the repo being changed plus only the repos it needs, rather than all of `~/Dev`:

```bash
tartarus run claude ~/Dev/web-app ~/Dev/shared-lib ~/Dev/api-docs
```

Extra paths are mounted at the same location as on the host [23]. Clone mode only protects the primary repository; extra workspaces are direct mounts [27].
- `tartarus` mounts extras read-only unless you add `:rw` to the path.
- It refuses an extra path that contains, or sits inside, the primary repo, because that would mount the repo directly and bypass clone mode.

### The shared kits

A kit is a `spec.yaml` that adds tools, credentials, network rules, and files to a sandbox at runtime [8], [12]. Both kits are mixins, so they layer onto any harness:
- **`kits/team-baseline`:** the team's network allowlist (npm and PyPI). It also removes the in-VM end of the host clipboard bridge.
- **`kits/no-root`:** removes the agent's passwordless `sudo` and locks the Docker socket to root. `TARTARUS_ALLOW_ROOT=1` opts out.

After any kit change, run `tartarus sign-kits`. It validates and signs every kit with the team key, which it creates on first use under `~/.config/tartarus/`, outside the repo. Then commit `kits/signing.pub` and the `kit.sig.bundle` files. If a kit changes without being re-signed, `sbx` refuses to install it and `audit` reports it.

Teams can also point `TARTARUS_BASELINE_KIT` at a pinned git copy (`git+https://github.com/yourorg/tartarus.git#ref=v1&dir=kits/team-baseline`) and add that source to `TARTARUS_KIT_SOURCES` [8]. Put shared config under `files/home/`, not `files/workspace/`, because kit files overwrite existing files and the workspace is the person's repo [8].

## Git workflow

Agents commit inside the sandbox; humans review and push from the host. We reach our self-hosted GitHub with `git push` rather than `gh`, and if the server sits on a private address, sandboxes can't reach it at all, because private IP ranges are blocked with no policy override [17]. That's the outcome we want.

Clone mode makes the handoff safe. The agent's commits are exposed to the host through a `sandbox-<name>` Git remote [18], while credentials, signing keys, and `.git/config` stay on the host [18]. The agent can't modify any tracked file or anything under `.git/` on the host, so it can't plant a `.git/hooks/pre-commit` or alter `.github/workflows/` [18].

```bash
tartarus review <sandbox-name> <branch>   # fetch, log, diffstat, and flag files that run on the host
git branch <branch> sandbox-<sandbox-name>/<branch>
tartarus rm <sandbox-name>                # remove the sandbox and the refs sbx leaves behind
```

Fetching isn't approval. Before checking out, building, or opening the branch in an IDE, review the files that execute code during normal development [19]. `tartarus review` lists every changed file of that kind and exits 2 when there are any. It covers:
- Git hooks and attributes;
- CI configuration;
- IDE and devcontainer config;
- build and task files;
- dependency manifests;
- environment managers such as `direnv`, `mise` and Nix;
- harness config that runs commands (`.claude/`, `.codex/`, `.mcp.json`);
- JS tool configs (`eslint.config.js`, `vite.config.ts`, `.prettierrc.js`), which IDEs and linters run on open, and Python startup hooks (`.pth`, `sitecustomize.py`);
- agent instruction files (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`). These are prompt injection aimed at the next agent you run on the host, outside the sandbox;
- every added or changed symlink, which can point a build or IDE at any host file.

Matching is case-insensitive (macOS opens `.VSCode/` as `.vscode/`), and both ends of a rename are checked.

Then push the branch to our server as usual.

### Server-side guardrails

- **Branch protection** on main and release branches: required PRs and human review, no force-pushes. The worst an agent can then do is push a junk branch.
- **CI trigger audit:** check whether any branch push auto-deploys, such as preview environments with prod data, deploy-on-tag, or pipelines that hold prod secrets on any branch. If so, a push is a path to prod regardless of the sandbox.

### Open questions

- [ ] Confirm our GitHub server resolves to a private address. If it's public-facing, add it to `policy/deny.txt` so pushes always go through human review.
- [ ] Decide whether teams need signed agent commits; if so, set up an isolated SSH agent with an agent-only key [25].

## Secrets hygiene

Inside `sbx`, host secrets aren't visible unless we pass them in, with two exceptions to watch. The host SSH agent is forwarded by default (`tartarus setup` turns it off) [22]. Registry credentials stored globally with `sbx secret set --registry -g` are written into `~/.docker/config.json` in every new sandbox [22], so don't store prod registry credentials that way. Anyone who runs an agent outside `sbx`, even briefly, should also follow these practices.

**1Password**

- Don't launch agents from a terminal where `op` is already authorized; an agent spawned there can call `op read`.
- Don't run agents under `op run`, or with `.env` files populated by `op inject`; child processes inherit those values.
- Unset `SSH_AUTH_SOCK` before launching, so the agent can't sign with keys held in 1Password's SSH agent.

**Vault**

- Keep `~/.vault-token` and `VAULT_*` env vars out of agent sessions.
- Leave the Vault address off sandbox egress allowlists, so a leaked token can't reach the server.
- If an agent genuinely needs Vault, give it its own auth role scoped to non-prod paths, so audit logs separate agent actions from human ones.

**Clean-shell launcher for sessions outside sbx:** `tartarus safe <harness>` runs

```bash
env -i HOME="$HOME" PATH="$PATH" TERM="$TERM" KUBECONFIG=/dev/null <harness command>
```

with each harness's own sandbox switched on: `copilot --sandbox`, `codex --sandbox workspace-write`, and `claude` with its default permission prompts. This drops `VAULT_TOKEN`, `AWS_*`, `SSH_AUTH_SOCK`, and anything injected by `op run`, and gives `kubectl` no clusters. It keeps `HOME`, so the harness's own sign-in still works, but so does the agent's view of `~/.vault-token`, which is why `sbx` stays the default.

## Lockdown layers

Every layer below was tested against `sbx` v0.48.0 on 2026-10-18 with Claude Code and Codex. Each check also has a control: the same probe with the protection removed, to prove the check can fail. `tartarus verify <sandbox>` re-runs the in-sandbox checks, and `tartarus audit` the host ones.

| Layer | What it stops | How it was proven |
|---|---|---|
| `deny-all` global policy | `balanced` allows about 190 destinations, including `**.amazonaws.com`, `**.googleapis.com`, GitHub and GitLab: ready-made exfiltration paths | `example.com`, S3, GCS, GitLab, pastebin and the cloud metadata IP all return 403 from the proxy. Direct TCP to the internet or to the host's LAN or VPN addresses is accepted by the interceptor but returns no data. Direct UDP, direct IPv6, and DNS for public names are blocked |
| Per-harness deny lists | The Claude kit allows `mcp-proxy.anthropic.com`, which reaches your claude.ai connectors (Gmail, Drive and so on) with your subscription. It also allows the remote-control bridge and self-update. The Codex kit allows GitHub | The policy log showed Claude contacting the connector proxy during a trivial task. With all of these denied, both agents still sign in, run tests and commit |
| SSH agent forwarding off, with a daemon restart | A host SSH agent, such as 1Password's, would be usable inside | A live throwaway agent on the host was invisible in the sandbox. With forwarding on, as a control, its key showed up |
| Host environment never passed in | Vault, AWS and 1Password variables in the launching shell | Canary values exported in the launching shell were absent from every process environment inside |
| Credentials stay on the host | Real OAuth or API tokens inside the VM | The credential files hold only proxy placeholders. A token scan in `verify` flags JWT, `sk-` and `gh*_` shapes (it caught a planted fake) |
| No root for the agent (`no-root` kit) | Guest root is the first step of any attack on the VM boundary | `sudo` asks for a password (the agent's is locked), and `docker ps` is denied. `sbx exec` re-adds the `sudo` and `docker` groups to every session, so the control is on the grants themselves. Holds across restarts |
| Clipboard bridge removed | The image runs `clipboard-bridge`, a Wayland clipboard-control server bridged towards the host | The bridge process and socket are gone after start and after restart. `clipboard.imagePaste=false` is pinned on the host as well |
| Host skills off | The host skills store linked into every sandbox | `--skills off` and `skills.defaultMode=off` |
| Clone mode plus read-only extras | The agent writing the host repo, its hooks or its config | The host repo's working tree, `.git/hooks` and `HEAD` were unchanged after agent commits, and writing to the source mount fails. Extras default to `:ro`, and overlapping mounts are refused, as are your home directory and its dotdirs (`~/.ssh`, `~/.aws`, `~/.config`) |
| Fingerprinted sandbox names | Re-attaching to an older sandbox, where `sbx` silently ignores the new flags | `verify` on a sandbox from before the deny lists fails: the connector proxy is reachable there |
| Signed kits | A modified kit, which runs code in every sandbox | Signed kits install. After a one-line edit without re-signing, `sbx` and `audit` both refuse |
| Approval prompts | Each blocked request becomes a pending prompt, and one click saves a permanent allow. An agent can trigger prompts on purpose | `audit` fails on any allow created by an approval (tested by approving `example.org` on a probe). Dismiss prompts, never allow them |
| No registered MCP servers | The sandbox MCP gateway is a daemon alias that deny rules don't cover. A registered host stdio server would run commands on the host for any agent | Denying the gateway had no effect, so the control is on the host: `audit` fails if `sbx mcp ls` lists anything |
| Resource limits | A runaway agent starving the host | 4 CPUs and 8 GB by default (`TARTARUS_CPUS`, `TARTARUS_MEMORY`) |

## Risks and limitations

`sbx` removes the host from the blast radius, but these gaps remain.

| Risk | Why it matters | Mitigation |
|---|---|---|
| Trust handoff | Pillar Security found sandbox bypasses in four major coding agents where the agent never broke the sandbox; it wrote files that host tools later trusted [24] | Clone mode for the primary repo; `tartarus review` before building or opening agent work [19] |
| Writable extra workspaces | Extra mounts stay direct and writable, even in clone mode [27] | `tartarus` mounts extras `:ro` unless told `:rw`; never mount all of `~/Dev` |
| The vendor API is an open channel | The agent must reach its own model API, and with OAuth it acts as you there (for example, Codex reaches `chatgpt.com`) | Inherent to running the agent at all. Deny everything else (done), and prefer API keys scoped to a team project over personal subscriptions |
| Persistent sandboxes | A sandbox, including anything a compromised agent planted in its home, persists across sessions for the same repo and lockdown | `tartarus rm` after merging work; a fresh sandbox per task for untrusted inputs |
| Public prod endpoints | Private ranges are blocked [17], but public prod APIs and cloud control planes are reachable if a rule allows them | `policy/deny.txt`; review `sbx policy log` |
| Allowlist creep | Every domain added to the kits, and every approved prompt, is a possible exfiltration path [16]. Even the npm registry is one: `npm publish` with a token an attacker plants in a prompt uploads to it | Keep `team-baseline` short. `audit` fails on approval-created allows. Drop `registry.npmjs.org` from the kit for repos that don't need it |
| Credentials passed in | Anything we give the sandbox is usable inside it | One model credential per harness; SSH forwarding off; no `github` secret (audited); no global registry secrets |
| CI as a path to prod | A pushed branch may trigger deploys or expose prod secrets | Branch protection and a CI trigger audit (see Git workflow) |
| Harness drift | Three harnesses change their flags, auth and defaults independently | Rely on `sbx`'s own per-agent defaults; Tartarus only picks the credential and kit |
| Product maturity | Docker marks parts of `sbx` as Early Access or Experimental [18], [19], and it changes quickly (Copilot moved from a built-in agent to a kit [21]) | Pin kit versions; re-check Docker's docs quarterly |
| macOS version | Requires macOS Tahoe 26 or later [10] | Already required company-wide; confirm there are no exceptions |
| Voluntary adoption | This is a team pattern, not enforced centrally | Easy defaults (`tartarus` launcher, shared kit) so the safe path is the easy one |

For teams that want an even stronger boundary, cloud sandboxes such as GHCP's cloud sandbox remove the laptop from the blast radius entirely [13], at the cost of latency and usage billing.

## Rollout plan

Start with one volunteer team, prove the pattern, then share it.

1. **Pilot:** one team runs all agent sessions, whichever harness each person prefers, through `tartarus run` for real work. Publish the kit and `policy/deny.txt` in this repo.
2. **Verify:** `tartarus verify <sandbox-name>` runs the host audit and the in-sandbox battery (see Lockdown layers). Review `sbx policy log` to confirm nothing unexpected was contacted. Repeat for each harness in use.
3. **Git:** adopt the clone-mode review flow, turn on branch protection, and run the CI trigger audit.
4. **Share:** demo the pattern to other teams, with this repo as the starting point.
5. **Iterate:** collect friction (blocked domains, missing tools, harness quirks) and fold fixes into the kit or launcher.

### What success looks like

- No standing prod credentials or routes reachable from agent sessions in pilot teams, for any harness.
- Pilot teams run long autonomous sessions without permission prompts or prod concerns.
- Kit and policy changes ship through this repo, not per-machine tweaks.

## References

[1] GitHub, "Using local sandboxing," *GitHub Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.github.com/en/copilot/how-tos/cloud-and-local-sandboxes/using-local-sandboxing

[2] GitHub, "Copilot CLI release v1.0.83," Sep. 4, 2026. [Online]. Available: https://github.com/github/copilot-cli/releases/tag/v1.0.83

[3] Qovery, "How to let AI coding agents deploy without handing them your cloud account." Accessed: Oct. 18, 2026. [Online]. Available: https://www.qovery.com/blog/governed-execution-ai-agent-deployments

[4] Docker, "Docker Sandboxes," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes.md

[5] Docker, "Why microVMs: The architecture behind Docker Sandboxes," *Docker Blog*. Accessed: Oct. 18, 2026. [Online]. Available: https://www.docker.com/blog/why-microvms-the-architecture-behind-docker-sandboxes/

[6] Docker, "Docker Sandboxes," product page. Accessed: Oct. 18, 2026. [Online]. Available: https://www.docker.com/products/docker-sandboxes/

[7] GitHub, "Local sandboxing for GitHub Copilot now generally available," *GitHub Changelog*, Oct. 7, 2026. [Online]. Available: https://github.blog/changelog/2026-10-07-local-sandboxing-for-gitHub-copilot-now-generally-available

[8] Docker, "Kits," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/customize/kits.md

[9] Docker, "Policies," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/security/policy.md

[10] Docker, "Get started with Docker Sandboxes," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/get-started.md

[11] Docker, "sbx policy init," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/reference/cli/sbx/policy/init

[12] Docker, "Customizing sandboxes," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/customize/

[13] S. Dubois, "GitHub Copilot sandboxing," *dsebastien.net*. Accessed: Oct. 18, 2026. [Online]. Available: https://www.dsebastien.net/github-copilot-sandboxing/

[14] Docker, "Connect VS Code to a sandbox," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/integrations/vscode/

[15] Docker, "Editor and app integrations," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/integrations/

[16] Docker, "Security model," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/security/

[17] Docker, "Default security posture," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/security/defaults/

[18] Docker, "Isolation layers," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/security/isolation/

[19] Docker, "Workspace trust," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/security/workspace

[20] Docker, "Copilot," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/agents/copilot/

[21] Docker, "sbx/copilot-kit," *Docker Hub*. Accessed: Oct. 18, 2026. [Online]. Available: https://hub.docker.com/r/sbx/copilot-kit

[22] Docker, "Credentials," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/security/credentials/

[23] Docker, "sbx create codex," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/reference/cli/sbx/create/codex/

[24] Pillar Security, "The week of sandbox escapes," *Pillar Security Blog*, Jul. 20, 2026. [Online]. Available: https://pillar.security/blog/the-week-of-sandbox-escapes

[25] M. Lee, "Sandboxing coding agents," *micahflee.com*. Accessed: Oct. 18, 2026. [Online]. Available: https://micahflee.com/sandboxing-coding-agents/

[26] Docker, "sbx/git-ssh-sign," *Docker Hub*. Accessed: Oct. 18, 2026. [Online]. Available: https://hub.docker.com/r/sbx/git-ssh-sign

[27] Docker, "Sandbox environment files," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/configuration/environment-files/

[28] Docker, "Claude Code," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/agents/claude-code/

[29] Docker, "Codex," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/agents/codex/

[30] Docker, "Agents," *Docker Docs*. Accessed: Oct. 18, 2026. [Online]. Available: https://docs.docker.com/ai/sandboxes/agents/
