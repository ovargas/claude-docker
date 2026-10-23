# claude-docker

> **Work in progress.** This is a personal setup under active development.
> Expect breaking changes, rough edges and incomplete isolation; review the
> known limits below before relying on it.

Run Claude Code with `--dangerously-skip-permissions` inside a sandbox that
can write only the current repo, read its sibling repos, run the repo's own
`docker compose`, and reach the internet only through a domain allowlist.

## Layout

```
host (macOS) ── Docker Desktop
                 └── sandbox-<repo>-<hash>      one compose project per repo
                      ├── proxy    Squid, the only container with internet access
                      ├── dind     private Docker daemon (privileged)
                      │    └── the repo's own compose services (postgres, redis, ...)
                      └── claude   Claude Code; shares dind's network namespace
```

| Service | Networks | Sees |
|---|---|---|
| `proxy` | `sandbox` + `egress` | `proxy/allowed-domains.txt` |
| `dind` | `sandbox` (internal, no internet) | the repo, its worktrees, its image cache volume |
| `claude` | dind's namespace | see [Filesystem access](#filesystem-access), plus `~/.claude-docker` as `$HOME`, a filtered `~/.gitconfig` (ro), the forwarded SSH agent |

Key properties:

- **Same paths as the host.** The repo is mounted at its host path in both
  `claude` and `dind`, so bind mounts in the project's compose file resolve and
  Claude's per-project history matches.
- **`localhost` works.** Ports published by the project's containers live in
  dind's namespace, which `claude` shares, so `localhost:5432` behaves like it
  does on the host.
- **Fails closed.** `dind` and `claude` have no route to the internet. Traffic
  that ignores the proxy simply fails.
- **Nested containers** reach the proxy through a `socat` relay on
  `172.17.0.1:3128` (dind's bridge gateway), injected by the Docker CLI config.

## Install

```sh
ln -s "$PWD/dclaude" ~/.local/bin/dclaude   # any dir on your PATH
dclaude sync                                 # once, from any repo (see below)
```

Images build on first run.

## Usage

```sh
cd ~/projects/acme/api
dclaude                  # Claude in YOLO mode, in $PWD
dclaude -p "explain X"   # any claude args pass through
dclaude mounts           # what the sandbox sees, and with which access
dclaude shell            # bash inside the sandbox
dclaude sync             # copy CLAUDE.md, settings, skills and plugins from the host
dclaude down             # stop this repo's sandbox (keeps image cache)
dclaude destroy          # also delete the cached images of this sandbox
dclaude rebuild          # rebuild images, updates Claude Code
dclaude proxy-reload     # apply allowed-domains.txt changes
dclaude proxy-logs       # look for TCP_DENIED to find missing domains
dclaude ps               # running sandboxes
```

## Filesystem access

Repos are expected at `~/projects/{client}/{repo}`. Running `dclaude` anywhere
inside `~/projects/acme/api` (or one of its worktrees) gives:

| Path | `claude` | `dind` |
|---|---|---|
| `~/projects/acme/api` | read-write | read-write |
| `~/projects/acme/api-worktrees/` (created if missing) | read-write | read-write |
| `~/projects/acme/` (siblings, shared docs) | read-only | — |
| secret files in siblings | empty | — |

- Everything uses the host paths, so relative references such as
  `../contracts-api` in `stack.md` resolve the same way inside the sandbox.
- From a worktree, the main repo is the writable one: a worktree's commits
  land in the main repo's `.git`.
- Siblings are never mounted into `dind`. It is privileged and the agent
  controls it, so a read-only flag there would not hold.
- Secret masking mounts an empty file over sibling files named `.env`,
  `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `.npmrc`, `.pypirc`, `.netrc`,
  `credentials.json`, `service-account*.json`, `*.tfvars`, and over any JSON
  under 64 KB containing `"private_key"`. `*.example`, `*.sample` and
  `*.template` stay readable. Edit `SECRET_NAMES` / `SECRET_EXCEPTIONS` in
  `dclaude`. The scan runs on every launch, so new files are picked up.
- The current repo's own secrets are not masked: the agent needs them to run it.
- Siblings are skipped when the parent is `/`, `~`, `~/projects` or `/Users`.
  `DCLAUDE_NO_SIBLINGS=1` skips them on purpose.
- The generated mount list lives in `~/.cache/dclaude/`, outside anything the
  sandbox can write, so the agent can't widen its own mounts for the next run.

## Image stacks

The `claude` image is a base (`Dockerfile`) plus one layer per toolchain the
repo needs, from `stacks/<name>/`:

```
claude-sandbox:base  ->  :go  ->  :go-node        layers in alphabetical order
```

| Stack | Gives | Versions |
|---|---|---|
| `go` | Go (latest stable at build time) | toolchain from `go.mod` (`GOTOOLCHAIN=auto`) |
| `node` | mise + corepack | Node from `.nvmrc` / `.node-version` / `.tool-versions`, package manager from `packageManager` |

- **Which stacks.** In order: `DCLAUDE_STACKS="go node"` for one run, the
  first matching rule in `stacks.conf`, then `detect_stacks` in `dclaude`,
  which looks at the repo's files up to two levels deep. `dclaude mounts`
  shows the resulting image.
- **Builds are cached.** Each layer is labeled with a hash of its recipe and
  everything below it, and rebuilt only when that changes.
  `dclaude rebuild` forces a fresh build (and a newer Go).
- **Recipes live here, not in the repos.** Images build on the host's Docker,
  outside the proxy. A Dockerfile inside the repo could be edited by the agent
  and run unsandboxed on the next launch.
- **Each stack has its own allowlist** (`stacks/<name>/allowed-domains.txt`),
  merged with `proxy/allowed-domains.txt` only for sandboxes using that stack.
- **Shared caches.** Go modules, Node versions and the pnpm store live in the
  `dclaude-cache` volume, shared by all sandboxes and kept by `destroy`.
- **Cloud domains are allowed when tools need them** (the Go stack allows
  `storage.googleapis.com`, where `proxy.golang.org` serves large modules).
  Access to cloud resources is blocked by keeping credentials out: no
  `~/.config/gcloud`, `~/.aws` or `~/.kube` mounts, no cloud env vars, and
  sibling secrets masked. A key committed or left in the current repo's
  `.env` would still be usable.
- The base keeps a system Node LTS because plugin hooks (e.g. Stripe's) run
  `node`. Inside a project with a pinned version, mise's shims take precedence.

To add a stack, create `stacks/<name>/Dockerfile` starting with
`ARG BASE` / `FROM ${BASE}`, and optionally `stacks/<name>/allowed-domains.txt`.

## Host config

`dclaude sync` copies host config into the sandbox home, one way:

- `~/.claude/CLAUDE.md` and `~/.claude/skills/` (symlinks resolved)
- `~/.claude/settings.json` and `statusline-command.sh`. Paths under
  `~/.claude` are rewritten to the sandbox home, hooks that call other host
  files (e.g. iTerm's `cc-status`) are dropped, and GitHub marketplaces
  switch to HTTPS git URLs. Merged over the sandbox's own settings.
- every GitHub marketplace in `~/.claude/plugins/known_marketplaces.json`,
  added by HTTPS URL
- every plugin enabled in `~/.claude/settings.json`, installed in the sandbox,
  except those in `plugins-excluded.txt` (skipped, disabled, and uninstalled
  if a previous sync installed them)
- the MCP servers listed in `mcp-allowed.txt`, copied from `~/.claude.json`
  with their credentials. The list replaces the sandbox's MCP config, so
  removing a name and syncing again revokes it. Add each server's domain to
  `proxy/allowed-domains.txt`.

Your real `~/.claude` is never mounted. A writable mount would let the agent
add hooks or plugin code that later runs unsandboxed on the host, and would
expose `.credentials.json` and every client's session history (`projects/`,
`history.jsonl`). Rerun `sync` after changing it there.
Plugins that call external services (MCP servers such as Stripe or Figma)
also need their domains in the allowlist.

## Credentials

| What | How |
|---|---|
| Claude login | Run `/login` once in the sandbox; it persists in `~/.claude-docker`. |
| SSH (git) | Docker Desktop forwards your SSH agent: keys are usable, never readable. Load them on the host with `ssh-add`. |
| GitHub HTTPS / `gh` | Export `SANDBOX_GH_TOKEN` with a fine-grained token scoped to the repo. Your regular `GH_TOKEN` is never passed. |
| Git identity | A copy of `~/.gitconfig` without `url.*` rewrites (the sandbox uses HTTPS for GitHub), read-only. |

`~/.claude-docker` is the sandbox's `$HOME`, separate from your real
`~/.claude`, so nothing the agent writes there runs on the host. Override the
location with `DCLAUDE_HOME`.

## Allowlist

Edit `proxy/allowed-domains.txt` (all sandboxes) or
`stacks/<name>/allowed-domains.txt` (sandboxes with that stack), then
`dclaude proxy-reload`. A leading
dot matches all subdomains. When something fails to download,
`dclaude proxy-logs` shows the denied domain.

## Known limits

- **Write isolation is filesystem-only for now.** The forwarded SSH agent (and
  any `SANDBOX_GH_TOKEN`) can still push to every repo your account can push
  to. Removing it in favor of a repo-scoped token is the next step.
- **Repo writes reach the host.** The agent can edit `.git/hooks`,
  `.git/config` (`core.hooksPath`) or `.claude/settings.json` in the repo, and
  those run on the host the next time you use git or Claude there. Review them
  after a session.
- **Inter-service HTTP inside nested containers goes to the proxy.** The proxy
  env is injected into every nested container, so a container calling
  `http://elasticsearch:9200` by service name is sent to Squid and fails.
  Add those names to `noProxy` in `docker-client-config.json`.
- **dind is privileged** within Docker Desktop's VM. That VM can see the folders
  shared in Docker Desktop's file-sharing settings; keep that list short.
- **Resources.** Each sandbox runs its own copies of the project's services.
