# msb-claude

A Docker image (`ubuntu-claude`) with [Claude Code](https://claude.com/claude-code) preinstalled, meant to be run as a [microsandbox](https://microsandbox.dev) (`msb`) microVM. It gives you a disposable, isolated sandbox where Claude Code can run and act (read/write files, execute commands, hit the network) without touching your host machine.

## Contents

- `ubuntu-claude/Dockerfile` — builds on top of `ubuntu:26.04`, installs Claude Code, skips the interactive onboarding (auth is handled via a token, see below), sets up a default status line, and installs [mise](https://mise.jdx.dev) plus Node.js (see the [Dev tools](#dev-tools) cookbook) and Docker (see the [Docker](#docker) cookbook).
- `ubuntu-claude/files/` — files copied into the image by the Dockerfile, laid out under `home/` to mirror their destination path relative to `/home/ubuntu` (e.g. `files/home/.gitconfig` → `~/.gitconfig`).

## Prerequisites

- **microsandbox (`msb`)** installed and working (requires hardware virtualization — KVM on Linux, Apple Silicon on macOS). Full setup instructions: [docs.microsandbox.dev](https://docs.microsandbox.dev).
- **Docker** installed on your host — only to [build the image yourself](#building-the-image-locally), msb doesn't need a running Docker daemon to run it.
- **Claude Code installed on your host machine**, with an active Claude subscription (or API access) — needed once, to generate the authentication token below.

## 1. Generate a Claude Code authentication token

On your **host** (not inside a sandbox), with Claude Code already installed and logged in:

```bash
claude setup-token
```

This prints a `CLAUDE_CODE_OAUTH_TOKEN`. It lets Claude Code authenticate non-interactively — no login flow needed inside the sandbox. Export it in the shell you'll use to create sandboxes (or keep it in a local `.env` you `source` — never commit it):

```bash
export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

## 2. Pull the image

```bash
msb pull ghcr.io/foo-coders/ubuntu-claude
```

The image is public and rebuilt weekly, to pick up Ubuntu and Claude Code updates. `latest` follows the newest build; each build is also tagged `YYYY-MM-DD-<short sha>` to pin a specific one. It is published for `linux/amd64` only: on Apple Silicon, [build the image locally](#building-the-image-locally) instead.

Every build carries a signed provenance attestation, verifiable with the [GitHub CLI](https://cli.github.com):

```bash
gh attestation verify oci://ghcr.io/foo-coders/ubuntu-claude:latest -R foo-coders/msb-claude
```

## 3. Create a sandbox

```bash
msb create \
  --name ubuntu-msb \
  --net public \
  -v ${PWD}:${PWD} \
  --workdir ${PWD} \
  --cpus 2 --max-cpus 8 \
  --memory 4G --max-memory 8G \
  --secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
  ghcr.io/foo-coders/ubuntu-claude
```

- `--name ubuntu-msb` — name of the sandbox, used to find/reuse it (`msb exec`, `msb rm`, ...).
- `--net public` — allow all outbound network access. See the [Network isolation](#network-isolation) cookbook for a more restricted setup.
- `-v ${PWD}:${PWD}` — bind-mount the current directory into the sandbox at the same path (use absolute path to avoid dynamic resolution change).
- `--workdir ${PWD}` — working directory inside the sandbox, aligned with the mount above.
- `--cpus 2 --max-cpus 8` / `--memory 4G --max-memory 8G` — baseline / burst resource limits.
- `--secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com"` — reads `$CLAUDE_CODE_OAUTH_TOKEN` from your host shell (step 1) and makes it available to the sandbox, scoped to `api.anthropic.com` only. See the [secrets documentation](https://docs.microsandbox.dev/sandboxes/secrets.md) for the full trust model.
- `ghcr.io/foo-coders/ubuntu-claude` — the image pulled in step 2.

The sandbox boots and stays idle, ready for `msb exec`.

## 4. Attach to the sandbox

```bash
msb exec ubuntu-msb -- bash
```

Opens a shell inside the running sandbox. From there, just run `claude` as usual — it's preinstalled and already authenticated via the injected token.

## 5. Remove the sandbox

```bash
msb rm ubuntu-msb
```

Stops (if needed) and removes the sandbox and its state. The image stays cached in msb — recreate a sandbox from it anytime with step 3.

## `claude-msb` helper

`cli/claude-msb` is a bash script wrapping steps 3 and 4: it manages one sandbox per directory, named `<current-dir>-<path-hash>-msb` (the hash — first 8 hex chars of the sha256 of the current directory path (`$PWD`, symlinks not resolved) — keeps `~/a/foo` and `~/b/foo` apart; characters msb doesn't accept in a sandbox name are replaced by `-`, leading ones dropped, and the directory name is cut to fit). It mounts the current directory, the host skills directory if `~/.agents/skills` exists, otherwise it warns and skips it (see [Adding skills](#adding-skills)) and a Docker disk (see [Docker](#docker)), and injects `CLAUDE_CODE_OAUTH_TOKEN`.

Install it on your `PATH` with `install -m 755 cli/claude-msb ~/.local/bin/claude-msb` (the file in the repo isn't executable; re-run the command to update it). It needs `msb`, and reads secrets from `~/.microsandbox/.env` (e.g. `CLAUDE_CODE_OAUTH_TOKEN=<token>`, plus `GH_OAUTH_TOKEN` for `--gh`).

```bash
cd ~/projects/foo
claude-msb --new      # create the sandbox for this directory and enter it
claude-msb            # later: resume it
claude-msb --replace  # recreate it from scratch
```

| Flag | Effect |
| --- | --- |
| `--gh` | Also inject `GH_OAUTH_TOKEN` for `github.com` and `api.github.com`. Needs `--new` or `--replace`. |
| `-h`, `--help` | Show usage. |
| `--new` | Create the sandbox instead of resuming it. Fails if it already exists. |
| `--no-net` | Restrict outbound network to `api.anthropic.com:443` (plus `github.com` and `api.github.com` with `--gh`), see [Network isolation](#network-isolation). Needs `--new` or `--replace`. |
| `--pull` | Pull the latest image first (default: only if missing). Needs `--new` or `--replace`. |
| `--replace` | Recreate the sandbox, whether or not it exists (implies creation). |
| `--terminal [NAME]` | Open the session in a detached terminal window (`foot` or `ptyxis`, default `foot`). |

## Cookbook

### Building the image locally

To run your own changes to the image, or on a host the published image doesn't support (e.g. Apple Silicon), build it with Docker and load it straight into msb's local image cache:

```bash
docker build ubuntu-claude/ -t ubuntu-claude && docker save ubuntu-claude | msb load
```

Then use `ubuntu-claude` instead of `ghcr.io/foo-coders/ubuntu-claude` as the image of `msb create`.

### Adding skills

To make [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) from your host available inside the sandbox, mount your skills directory read-only at `/home/ubuntu/.host/.agents/skills`. That specific path is expected by a `SessionStart` hook (`files/home/.claude/hooks/relink-skills.sh`), which scans it on every session start and symlinks each skill directory it finds into `~/.claude/skills` — no manual symlinking needed. The example below assumes skills are managed with [`npx skills`](https://www.npmjs.com/package/skills) installed globally on the host, which keeps them under `~/.agents/skills`:

```bash
msb create \
  --name ubuntu-msb \
  --net public \
  -v ${PWD}:${PWD} \
  -v ${HOME}/.agents/skills:/home/ubuntu/.host/.agents/skills:ro \
  --workdir ${PWD} \
  --cpus 2 --max-cpus 8 \
  --memory 4G --max-memory 8G \
  --secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
  ghcr.io/foo-coders/ubuntu-claude
```

- `-v ${HOME}/.agents/skills:/home/ubuntu/.host/.agents/skills:ro` — mounts the host's skills directory read-only at the expected path. Adjust the source path to wherever your skills actually live; the destination must stay `/home/ubuntu/.host/.agents/skills` for the relink hook to pick it up.

The hook only manages symlinks it created itself: it leaves alone anything that's already a real file/dir or a symlink pointing elsewhere at the same name in `~/.claude/skills`, and it removes symlinks it previously created once their source skill disappears from the mount. It re-runs on every session start, so adding, removing, or updating skills on the host only requires restarting the Claude Code session inside the sandbox — not recreating it.

Volumes can only be set at `msb create` time (not added later with `msb modify`) — remove and recreate the sandbox if you need to change the mount.

### GitHub setup

The image ships with [`gh`](https://cli.github.com) preconfigured to authenticate git over HTTPS (`files/home/.gitconfig` wires `credential.helper` to `gh auth git-credential` for `github.com` and `gist.github.com`), plus a `PreToolUse` hook (`files/home/.claude/hooks/setup-git-identity-from-gh.sh`) that runs before `git add`/`git commit` and fills in whichever of git `user.name`/`user.email` isn't already set, from the authenticated `gh` account — any value you've already configured is left untouched. This lets Claude push commits, open PRs, and use `gh` commands from inside the sandbox.

On your **host**, generate a token `gh` can use non-interactively, e.g. from an account already logged in via `gh auth login`:

```bash
export GH_OAUTH_TOKEN=$(gh auth token)
```

Then create the sandbox as in step 3, adding two `--secret` flags for that token — one per host `gh` talks to (`github.com` for git/credential operations, `api.github.com` for `gh api`/`gh pr`/... calls):

```bash
msb create \
  --name ubuntu-msb \
  --net public \
  -v ${PWD}:${PWD} \
  --workdir ${PWD} \
  --cpus 2 --max-cpus 8 \
  --memory 4G --max-memory 8G \
  --secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
  --secret "GH_OAUTH_TOKEN@api.github.com" \
  --secret "GH_OAUTH_TOKEN@github.com" \
  ghcr.io/foo-coders/ubuntu-claude
```

- `--secret "GH_OAUTH_TOKEN@api.github.com"` / `--secret "GH_OAUTH_TOKEN@github.com"` — reads `$GH_OAUTH_TOKEN` from your host shell and makes it available to the sandbox, scoped to those two hosts only (`files/home/.config/gh/hosts.yml` references it as `$MSB_GH_OAUTH_TOKEN`, the placeholder `msb` injects for a secret bound this way — see the [secrets documentation](https://docs.microsandbox.dev/sandboxes/secrets.md)).

If `GH_OAUTH_TOKEN` isn't set, `gh` inside the sandbox has no credentials: `gh auth git-credential` fails, so git operations over HTTPS and the identity-setup hook fail too.

### Dev tools

Dev tool and language runtime versions are managed with [mise](https://mise.jdx.dev), a polyglot version manager (a single replacement for `nvm`, `pyenv`, `rbenv`, ...). It's installed in the image and activated in `~/.bashrc` (`eval "$(mise activate bash)"`), so tools it manages are on `PATH` in every interactive shell — including the one Claude Code runs commands in.

Only Node.js is preinstalled. Anything else is installed on demand, inside the sandbox:

```bash
mise use -g python@3.12   # install and pin a tool globally
mise registry             # list known tools and their short names
mise ls-remote python     # list available versions of a tool
```

The image ships a baseline `~/.claude/CLAUDE.md` (`files/home/.claude/CLAUDE.md`) telling the agent to reach for `mise use -g <tool>@<version>` rather than `apt`, `nvm`, or `pyenv` when a command is missing — so Claude installs missing runtimes itself, consistently, without being asked each time.

Installs land in the sandbox's own filesystem, so they disappear with `msb rm`. To make a toolchain permanent, add a `mise use -g ...` line to the Dockerfile and rebuild; to pin versions per project, commit a `mise.toml` in the repo you mount — mise picks it up automatically when Claude `cd`s into it.

### Docker

The image ships Docker CE from [Docker's official apt repo](https://docs.docker.com/engine/install/ubuntu/) (engine, CLI, and the `docker compose`/`docker buildx` plugins), so Claude can build and run containers for Docker-based projects entirely inside the sandbox — a separate `dockerd`, isolated from your host's Docker.

Docker needs a real ext4 filesystem for its storage: the sandbox's root is an overlayfs, and Docker's overlay storage can't be nested on top of it. Create the sandbox as in step 3, adding a dedicated disk mounted on `/var/lib/docker`:

```bash
msb create \
  --name ubuntu-msb \
  --net public \
  -v ${PWD}:${PWD} \
  --mount-owned /var/lib/docker:kind=disk,size=10G \
  --workdir ${PWD} \
  --cpus 2 --max-cpus 8 \
  --memory 4G --max-memory 8G \
  --secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
  ghcr.io/foo-coders/ubuntu-claude
```

- `--mount-owned /var/lib/docker:kind=disk,size=10G` — attaches a 10G ext4 disk owned by the sandbox at Docker's data directory. Images, containers, and build cache live there and are deleted along with the sandbox by `msb rm`. Size it for the images you expect to build.

The daemon doesn't start at boot. The image's baseline `~/.claude/CLAUDE.md` (`files/home/.claude/CLAUDE.md`) tells Claude how to start `dockerd` when a task needs it, how to spot a missing `/var/lib/docker` disk, and how to handle msb's TLS interception, which containers don't trust out of the box. Without the disk, `dockerd` still starts, but every `docker run`/`docker build` fails with an overlay mount error.

Mounts can only be set at `msb create` time (not added later with `msb modify`) — remove and recreate the sandbox if you need to add the disk.

#### HTTPS inside containers

msb intercepts all outbound TLS from the sandbox and re-signs it with its own CA (`/.msb/tls/ca.pem`). The sandbox trusts that CA, so `dockerd` pulls images fine, but containers don't: any HTTPS call from a container, or from a `RUN` step of a `docker build`, fails with a certificate verification error until msb's CA is added to the container's trust store.

To run a container, mount msb's CA over the image's CA bundle (path for Debian/Ubuntu/Alpine-based images, other distros keep it elsewhere):

```bash
docker run -v /.msb/tls/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro <image>
```

To build an image, the CA has to be added from within the Dockerfile, before the steps that hit the network: copy `/.msb/tls/ca.pem` into the build context and install it into the image's CA bundle (e.g. `COPY` it to `/usr/local/share/ca-certificates/msb-ca.crt` then `RUN update-ca-certificates` on Debian/Ubuntu). The image's baseline `~/.claude/CLAUDE.md` tells Claude to apply this locally without committing it to the project's Dockerfile.

To build `ubuntu-claude` itself from inside a sandbox, pass msb's CA with the `EXTRA_CA_CERT` build arg, so the build's HTTPS downloads (Claude installer, `gh`, mise, Docker repo) trust msb's TLS interception:

```bash
docker build --build-arg EXTRA_CA_CERT="$(cat /.msb/tls/ca.pem)" ubuntu-claude/ -t ubuntu-claude
```

The CA is added by a dedicated build stage, only built when `EXTRA_CA_CERT` is set: a regular build (e.g. on your host) has no trace of it. An image built with it keeps trusting that CA, which is harmless inside msb since every sandbox already trusts msb's CA. The build arg stays recorded in `docker history`, which shows which CA an image was built with.

### Network isolation

To restrict the sandbox's network access to only the Anthropic API (instead of full outbound access), replace `--net public` with `--no-net` plus a `--net-rule` allowing just that destination:

```bash
msb create \
  --name ubuntu-msb-isolated \
  --no-net \
  --net-rule "allow@api.anthropic.com:tcp:443" \
  -v ${PWD}:${PWD} \
  --workdir ${PWD} \
  --cpus 2 --max-cpus 8 \
  --memory 4G --max-memory 8G \
  --secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
  ghcr.io/foo-coders/ubuntu-claude
```

- `--no-net` — disables outbound network access by default (replaces `--net public`).
- `--net-rule "allow@api.anthropic.com:tcp:443"` — allows traffic to `api.anthropic.com` on TCP/443 only, isolating the sandbox while still letting Claude Code reach the API.

⚠️ This network isolation doesn't block everything: Claude Code's `Web Search` tool goes through an Anthropic-hosted backend (not the sandbox's own network), so it can still perform web searches even with `--no-net`.

Network policies can only be set at `msb create` time (not added later with `msb modify`) — remove and recreate the sandbox if you need to change them.

## Going further

A few other `msb` commands that are handy while experimenting (see [CLI overview](https://docs.microsandbox.dev/cli/overview.md) for the full reference):

```bash
msb ls                                # list all sandboxes
msb ps -a                             # status of running (and, with -a, stopped) sandboxes
msb inspect <sandbox>                 # detailed config/status of a sandbox
msb metrics -wa                       # live CPU/memory/disk/network usage, all sandboxes
msb logs <sandbox>                    # captured stdout/stderr of a sandbox
msb logs <sandbox> --source system    # msb system logs (including blocked requests)
msb copy <SRC> <DST>                  # copy files host<->sandbox or sandbox<->sandbox (prefix sandbox-side paths with `name:`)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
