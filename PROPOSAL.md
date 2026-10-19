# Tartarus: Running AI Coding Agents in Docker Sandboxes (sbx)

2026-10-18 · Luke Hansen

> In Greek myth, Tartarus is the prison that held the Titans: powerful, and kept where they can't reach the world above. Tartarus does the same for coding agents.

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

Adding another `sbx`-supported harness (Gemini, Cursor, OpenCode and others [30]) is one `case` arm in `bin/tartarus`.

### VS Code

VS Code connects to a sandbox over Remote-SSH, so the editor stays on the host while files, terminals, and extensions run inside the sandbox [14]. Copilot agent mode's edits and commands, and any Claude Code or Codex extension, therefore run in the VM.

1. Run `sbx setup ssh` once (requires Docker Sandboxes 0.37.0 or later) [15].
2. Create a sandbox for the project: `sbx create --name <project> shell .`
3. In VS Code, run **Remote-SSH: Connect to Host…** and enter `<project>.sbx`, then open the mounted workspace with the remote folder picker [14].

The network policy must allow Microsoft's VS Code download domains and the harness's endpoints, because the first connection installs the VS Code server inside the sandbox [14]. On macOS, if VS Code loops on reconnect, set `remote.SSH.useLocalServer` to `false` [14].

- [ ] Confirm our macOS Tahoe 26+ requirement covers every developer Mac, since `sbx` needs it [10].

## Why sbx

`sbx` puts the whole agent in a separate microVM with its own kernel, Docker daemon, filesystem, and network [4], [5]. By default it can't reach the host filesystem outside the workspace, the host Docker daemon, the host network or localhost, or other sandboxes, and these can't be unblocked by policy [17]. Copilot CLI, Claude Code and Codex are all supported agents [30], so one boundary covers every harness.

One host connection is on by default: if `SSH_AUTH_SOCK` is set, the host SSH agent is forwarded into the sandbox [22]. `tartarus setup` turns that off.

| | Harness built-in sandbox (GHCP shown) | Docker Sandboxes (`sbx`) |
|---|---|---|
| Isolation | OS-level controls via Microsoft eXecution Container [7] | Dedicated microVM per session [5] |
| What's isolated | Most commands the agent runs; the agent runs on the host [1] | Everything, including the agent |
| What the agent sees | Your real filesystem, minus the policy | Only the mounted project folder |
| Credentials | Git and GitHub credentials passed through by default [1] | Held on the host and added by a proxy; never enter the VM [8], [22] |
| Network | Configurable | Deny-by-default proxy on the host; raw TCP, UDP, and ICMP blocked; private IP ranges, loopback, and link-local blocked [17] |
| Escape hatch | Can request to run one command outside [1] | None built in |
| Same model for every harness | No, each harness has its own | Yes |
| Requirements | Built into the harness, free | macOS Tahoe 26+ on Macs; Docker Desktop not required [6], [10] |

In short: a harness sandbox is a fence inside your house, and `sbx` is a separate building with only your project carried in.

## Team setup

Setup is four commands per machine, plus the `tartarus` repo the team maintains in git: `bin/tartarus` (the launcher), `kits/team-baseline/` (the shared kit) and `policy/deny.txt` (prod hostnames).

1. **Install `sbx` and sign in** [4]:
   - macOS: `brew install docker/tap/sbx`
   - Ubuntu: `sudo apt-get install docker-sbx` (after adding Docker's repo)
   - Then: `sbx login`, and put `tartarus/bin` on your `PATH`.
2. **Harden the host connections and set the network policy once:** `tartarus setup`. It runs:

   ```bash
   sbx settings set ssh.agentForwardingEnabled false
   sbx settings set kit.allowedSources '["docker.io/sbx/","github.com/yourorg/"]'
   sbx policy init balanced
   sbx policy deny network "<each host in policy/deny.txt>"
   ```

   SSH agent forwarding is on by default [22], and with 1Password's SSH agent it would hand the sandbox every key we hold. The setting is documented alongside Docker's signing kit [26]. If a team needs signed agent commits, run an isolated SSH agent loaded only with an agent-only key [25]. Restricting kit sources limits which kits can run [8], since kits execute code in the sandbox; `kit.allowedSources` replaces the whole list [27], and `TARTARUS_KIT_SOURCES` overrides ours.

   Private IP ranges, loopback, and link-local addresses are blocked for every sandbox [17], so internal services on private addresses are already unreachable. Deny rules are for prod endpoints with public addresses, such as public APIs and cloud control planes [9]. `balanced` includes broad wildcards [11], [16]; once the pilot shows which domains are actually used, move to `deny-all` with explicit allows.
3. **Give the sandbox only the model credential:** `tartarus login <harness>`.
   - **Copilot:** stores only the `copilot` secret (`COPILOT_GITHUB_TOKEN`, injected for `*.githubcopilot.com` and `copilot.github.com`). We deliberately skip the kit's `github` secret (`GH_TOKEN`, injected for `github.com`) [21]: our code lives on our own GitHub server, and the agent shouldn't push anywhere.
   - **Claude Code:** sign in with `/login` inside the sandbox (OAuth, token stays on the host), or store an API key with `sbx secret set anthropic` [22], [28].
   - **Codex:** `sbx secret set openai --oauth` signs in on the host and keeps the tokens in the OS keychain [29].

   The proxy adds the credential to matching requests, and the sandbox only ever sees a sentinel value [22].
4. **Run the agent in clone mode with the kits:** `tartarus run <harness>`, which runs:

   ```bash
   sbx run --clone \
     --kit "$TARTARUS_BASELINE_KIT" \
     [--kit "docker.io/sbx/copilot-kit:latest"]   # copilot only
     <copilot|claude|codex> [paths...] [-- agent args]
   ```

   In clone mode the agent works on a private in-VM clone, and the host repository is mounted read-only [18]. Arguments after `--` that start with `-` are added after the harness's autonomy flags; a bare word replaces them [28], [29]. Docker is moving Copilot from a built-in agent to a kit; older `sbx` versions use plain `sbx run copilot` [21].

Sandboxes don't pick up user-level harness config such as `~/.claude` or `~/.codex`; only project-level config in the workspace is visible [28], [29]. Shared agent instructions (`CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`) therefore belong in the repo, or in the baseline kit's `files/home/`.

### Multi-repo work

Mount the repo being changed plus only the repos it needs, read-only where possible, rather than all of `~/Dev`:

```bash
tartarus run claude ~/Dev/web-app ~/Dev/shared-lib ~/Dev/api-docs:ro
```

Extra paths are mounted at the same location as on the host, and `:ro` makes them read-only [23]. Clone mode only protects the primary repository; extra workspaces stay direct-mounted and writable unless marked `:ro` [27].

### The shared baseline kit

A kit is a `spec.yaml` that adds tools, credentials, network rules, and files to a sandbox at runtime [8], [12]. The baseline is a `mixin`, so it layers onto any harness. Teams should point `TARTARUS_BASELINE_KIT` at the pinned git copy, so we can update it without breaking anyone [8]:

```bash
export TARTARUS_BASELINE_KIT="git+https://github.com/yourorg/tartarus.git#ref=v1&dir=kits/team-baseline"
```

```yaml
# kits/team-baseline/spec.yaml
schemaVersion: "2"
kind: mixin
name: team-baseline
description: Team defaults for running AI coding agents in sbx

permissions:
  network:
    allow:
      - registry.npmjs.org
      - pypi.org
      - files.pythonhosted.org

setup:
  install:
    - command: "apt-get update && apt-get install -y jq"
```

Validate changes with `sbx kit validate ./kits/team-baseline` before publishing. Put shared config under `files/home/`, not `files/workspace/`, because kit files overwrite existing files and the workspace is the person's repo [8].

## Git workflow

Agents commit inside the sandbox; humans review and push from the host. We reach our self-hosted GitHub with `git push` rather than `gh`, and if the server sits on a private address, sandboxes can't reach it at all, because private IP ranges are blocked with no policy override [17]. That's the outcome we want.

Clone mode makes the handoff safe. The agent's commits are exposed to the host through a `sandbox-<name>` Git remote [18], while credentials, signing keys, and `.git/config` stay on the host [18]. The agent can't modify any tracked file or anything under `.git/` on the host, so it can't plant a `.git/hooks/pre-commit` or alter `.github/workflows/` [18].

```bash
git fetch sandbox-<name>
git log main..sandbox-<name>/<branch>
git diff main...sandbox-<name>/<branch>
```

Fetching isn't approval. Before checking out, building, or opening the branch in an IDE, review the files that execute code during normal development: Git hooks, CI configuration, IDE task configs, build scripts, and harness config that runs commands (`.claude/settings.json` hooks, `.codex/`, Copilot instructions) [19]. Then push the branch to our server as usual.

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

## Risks and limitations

`sbx` removes the host from the blast radius, but these gaps remain.

| Risk | Why it matters | Mitigation |
|---|---|---|
| Trust handoff | Pillar Security found sandbox bypasses in four major coding agents where the agent never broke the sandbox; it wrote files that host tools later trusted [24] | Clone mode for the primary repo; review hooks, CI config, IDE tasks, build scripts and harness config before building or opening agent work [19] |
| Writable extra workspaces | Extra mounts stay direct and writable, even in clone mode [27] | Mount extras with `:ro`; never mount all of `~/Dev` |
| Public prod endpoints | Private ranges are blocked [17], but public prod APIs and cloud control planes are reachable if a rule allows them | `policy/deny.txt`; review `sbx policy log` |
| Broad default allowlist | `balanced` includes broad wildcards [16], which are paths for exfiltrating code | Move to `deny-all` plus explicit allows after the pilot |
| Credentials passed in | Anything we give the sandbox is usable inside it | One model credential per harness; SSH forwarding off; no global registry secrets |
| CI as a path to prod | A pushed branch may trigger deploys or expose prod secrets | Branch protection and a CI trigger audit (see Git workflow) |
| Harness drift | Three harnesses change their flags, auth and defaults independently | Rely on `sbx`'s own per-agent defaults; Tartarus only picks the credential and kit |
| Product maturity | Docker marks parts of `sbx` as Early Access or Experimental [18], [19], and it changes quickly (Copilot moved from a built-in agent to a kit [21]) | Pin kit versions; re-check Docker's docs quarterly |
| macOS version | Requires macOS Tahoe 26 or later [10] | Already required company-wide; confirm there are no exceptions |
| Voluntary adoption | This is a team pattern, not enforced centrally | Easy defaults (`tartarus` launcher, shared kit) so the safe path is the easy one |

For teams that want an even stronger boundary, cloud sandboxes such as GHCP's cloud sandbox remove the laptop from the blast radius entirely [13], at the cost of latency and usage billing.

## Rollout plan

Start with one volunteer team, prove the pattern, then share it.

1. **Pilot:** one team runs all agent sessions, whichever harness each person prefers, through `tartarus run` for real work. Publish the kit and `policy/deny.txt` in this repo.
2. **Verify:** `tartarus verify <sandbox-name>` confirms the sandbox shows no host secrets in `env`, no SSH agent (`ssh-add -l`), and no kube context. Review `sbx policy log` to confirm nothing unexpected was contacted. Repeat for each harness in use.
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
