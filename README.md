# claude-msb

`claude-msb` runs [Claude Code](https://claude.com/claude-code) in a disposable [microsandbox](https://microsandbox.dev) (`msb`) microVM, one sandbox per project directory. Claude can read and write your project, run commands and reach the network without touching the rest of your machine.

```bash
cd ~/projects/foo
claude-msb --new   # create the sandbox for this directory and enter it
claude              # inside the sandbox: Claude Code, already authenticated
```

The sandbox runs the [`ubuntu-claude` image](#the-ubuntu-claude-image), published by this repo.

## Quick start

### Prerequisites

- **microsandbox (`msb`)** installed and working (requires hardware virtualization — KVM on Linux, Apple Silicon on macOS). Full setup instructions: [docs.microsandbox.dev](https://docs.microsandbox.dev).
- **Claude Code installed on your host machine**, with an active Claude subscription (or API access) — needed once, to generate the authentication token below.
- **bash**, plus [foot](https://codeberg.org/dnkl/foot) or [ptyxis](https://gitlab.gnome.org/chergert/ptyxis) only if you use `--terminal`.

### 1. Install the CLI

```bash
git clone https://github.com/foo-coders/msb-claude.git
install -m 755 msb-claude/cli/claude-msb ~/.local/bin/claude-msb
```

`~/.local/bin` must be on your `PATH`. The copy doesn't follow the repository: re-run `install` after a `git pull` to update it.

### 2. Generate a Claude Code authentication token

On your **host** (not inside a sandbox), with Claude Code already installed and logged in:

```bash
claude setup-token
```

This prints a `CLAUDE_CODE_OAUTH_TOKEN`. It lets Claude Code authenticate non-interactively — no login flow needed inside the sandbox. Put it in `~/.microsandbox/.env`, which `claude-msb` loads, and keep that file private (never commit it):

```bash
mkdir -p ~/.microsandbox
echo 'CLAUDE_CODE_OAUTH_TOKEN=<token>' >> ~/.microsandbox/.env
chmod 600 ~/.microsandbox/.env
```

`claude-msb` hands the token to the sandbox as an `msb` secret scoped to `api.anthropic.com` only: the process inside never sees the real value, and it is only substituted into requests to that host. See the [secrets documentation](https://docs.microsandbox.dev/sandboxes/secrets.md) for the full trust model.

### 3. Create a sandbox and enter it

```bash
cd ~/projects/foo
claude-msb --new
```

The first run pulls the image, creates the sandbox and opens a shell in it. From there, just run `claude`.

## Usage

```bash
claude-msb            # resume the sandbox of the current directory
claude-msb --new      # create it, then enter it
claude-msb --replace  # recreate it from scratch
```

Each directory gets its own sandbox, named `<current-dir>-<path-hash>-msb` (the hash — first 8 hex chars of the sha256 of the current directory path (`$PWD`, symlinks not resolved) — keeps `~/a/foo` and `~/b/foo` apart; characters msb doesn't accept in a sandbox name are replaced by `-`, leading ones dropped, and the directory name is cut to fit). Resuming only works from the directory the sandbox was created in.

| Flag | Effect |
| --- | --- |
| `--gh` | Also inject `GH_OAUTH_TOKEN` for `github.com` and `api.github.com`, see [GitHub](#github). Needs `--new` or `--replace`. |
| `-h`, `--help` | Show usage. |
| `--new` | Create the sandbox instead of resuming it. Fails if it already exists. |
| `--no-net` | Restrict outbound network to `api.anthropic.com:443` (plus `github.com` and `api.github.com` with `--gh`), see [Network isolation](#network-isolation). Needs `--new` or `--replace`. |
| `--pull` | Pull the latest image first (default: only if missing). Needs `--new` or `--replace`. |
| `--replace` | Recreate the sandbox, whether or not it exists (implies creation). |
| `--terminal [NAME]` | Open the session in a detached terminal window (`foot` or `ptyxis`, default `foot`). |

### What a sandbox gets

Sandbox settings can only be set at creation (not added later with `msb modify`): use `--replace` to change them.

- **Project:** the current directory, bind-mounted at the same path, which is also the working directory.
- **Resources:** 2 CPUs and 4G of memory, bursting up to 8 CPUs and 8G.
- **Network:** full outbound access, unless `--no-net`.
- **Token:** `CLAUDE_CODE_OAUTH_TOKEN` as a secret for `api.anthropic.com`, and `GH_OAUTH_TOKEN` for GitHub with `--gh`. `claude-msb` stops before creating the sandbox if one of them is missing from the environment.
- **Skills:** your host `~/.agents/skills` directory, read-only, if it exists; otherwise the sandbox is created without it, with a message. See [Skills](#skills).
- **Docker:** a dedicated 10G disk on `/var/lib/docker`, see [Docker](#docker).

## Cookbook

### GitHub

The image ships [`gh`](https://cli.github.com) preconfigured to authenticate git over HTTPS (`files/home/.gitconfig` wires `credential.helper` to `gh auth git-credential` for `github.com` and `gist.github.com`), plus a `PreToolUse` hook (`files/home/.claude/hooks/setup-git-identity-from-gh.sh`) that runs before `git add`/`git commit` and fills in whichever of git `user.name`/`user.email` isn't already set, from the authenticated `gh` account — any value you've already configured is left untouched. This lets Claude push commits, open PRs, and use `gh` commands from inside the sandbox.

Add a token `gh` can use non-interactively to `~/.microsandbox/.env`, e.g. from an account already logged in via `gh auth login`:

```bash
echo "GH_OAUTH_TOKEN=$(gh auth token)" >> ~/.microsandbox/.env
```

Then create the sandbox with `--gh`:

```bash
claude-msb --new --gh
```

The token is scoped to `github.com` and `api.github.com` (`files/home/.config/gh/hosts.yml` references it as `$MSB_GH_OAUTH_TOKEN`, the placeholder `msb` injects for a secret bound this way). Without `--gh`, `gh` inside the sandbox has no credentials: `gh auth git-credential` fails, so git operations over HTTPS and the identity-setup hook fail too.

### Network isolation

`--no-net` restricts the sandbox's outbound network to `api.anthropic.com` on TCP/443, just enough for Claude Code to reach the API (plus `github.com` and `api.github.com` with `--gh`):

```bash
claude-msb --new --no-net
```

Everything else is blocked, including package installs (`mise`, `apt`) and image pulls from inside the sandbox's Docker.

⚠️ This network isolation doesn't block everything: Claude Code's `Web Search` tool goes through an Anthropic-hosted backend (not the sandbox's own network), so it can still perform web searches even with `--no-net`.

### Skills

To make [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) from your host available inside the sandbox, keep them in `~/.agents/skills` — where [`npx skills`](https://www.npmjs.com/package/skills) installed globally puts them. `claude-msb` mounts that directory read-only at `/home/ubuntu/.host/.agents/skills`, the path expected by a `SessionStart` hook (`files/home/.claude/hooks/relink-skills.sh`) that scans it on every session start and symlinks each skill directory it finds into `~/.claude/skills` — no manual symlinking needed.

The hook only manages symlinks it created itself: it leaves alone anything that's already a real file/dir or a symlink pointing elsewhere at the same name in `~/.claude/skills`, and it removes symlinks it previously created once their source skill disappears from the mount. It re-runs on every session start, so adding, removing, or updating skills on the host only requires restarting the Claude Code session inside the sandbox — not recreating it. Creating the sandbox _before_ `~/.agents/skills` exists does require `--replace`, since volumes can't be added later.

### Docker

The image ships Docker CE from [Docker's official apt repo](https://docs.docker.com/engine/install/ubuntu/) (engine, CLI, and the `docker compose`/`docker buildx` plugins), so Claude can build and run containers for Docker-based projects entirely inside the sandbox — a separate `dockerd`, isolated from your host's Docker.

Docker needs a real ext4 filesystem for its storage: the sandbox's root is an overlayfs, and Docker's overlay storage can't be nested on top of it. `claude-msb` attaches a dedicated 10G ext4 disk at `/var/lib/docker` (`--mount-owned /var/lib/docker:kind=disk,size=10G`). Images, containers, and build cache live there and are deleted along with the sandbox. Size it for the images you expect to build.

The daemon doesn't start at boot. The image's baseline `~/.claude/CLAUDE.md` (`files/home/.claude/CLAUDE.md`) tells Claude how to start `dockerd` when a task needs it, how to spot a missing `/var/lib/docker` disk, and how to handle msb's TLS interception, which containers don't trust out of the box. Without the disk, `dockerd` still starts, but every `docker run`/`docker build` fails with an overlay mount error.

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

### Dev tools

Dev tool and language runtime versions are managed with [mise](https://mise.jdx.dev), a polyglot version manager (a single replacement for `nvm`, `pyenv`, `rbenv`, ...). It's installed in the image and activated in `~/.bashrc` (`eval "$(mise activate bash)"`), so tools it manages are on `PATH` in every interactive shell — including the one Claude Code runs commands in.

Only Node.js is preinstalled. Anything else is installed on demand, inside the sandbox:

```bash
mise use -g python@3.12   # install and pin a tool globally
mise registry             # list known tools and their short names
mise ls-remote python     # list available versions of a tool
```

The image ships a baseline `~/.claude/CLAUDE.md` (`files/home/.claude/CLAUDE.md`) telling the agent to reach for `mise use -g <tool>@<version>` rather than `apt`, `nvm`, or `pyenv` when a command is missing — so Claude installs missing runtimes itself, consistently, without being asked each time.

Installs land in the sandbox's own filesystem, so they disappear with the sandbox. To make a toolchain permanent, add a `mise use -g ...` line to the Dockerfile and rebuild; to pin versions per project, commit a `mise.toml` in the repo you mount — mise picks it up automatically when Claude `cd`s into it.

## The `ubuntu-claude` image

`claude-msb` creates its sandboxes from `ghcr.io/foo-coders/ubuntu-claude`, a Docker image with Claude Code preinstalled.

- `ubuntu-claude/Dockerfile` — builds on top of `ubuntu:26.04`, installs Claude Code, skips the interactive onboarding (auth is handled via a token, see [Quick start](#2-generate-a-claude-code-authentication-token)), sets up a default status line, and installs [mise](https://mise.jdx.dev) plus Node.js (see [Dev tools](#dev-tools)) and Docker (see [Docker](#docker)).
- `ubuntu-claude/files/` — files copied into the image by the Dockerfile, laid out under `home/` to mirror their destination path relative to `/home/ubuntu` (e.g. `files/home/.gitconfig` → `~/.gitconfig`).

The image is public and rebuilt weekly, to pick up Ubuntu and Claude Code updates. `latest` follows the newest build; each build is also tagged `YYYY-MM-DD-<short sha>` to pin a specific one. It is published for `linux/amd64` only: on Apple Silicon, [build the image locally](#building-the-image-locally) instead. `claude-msb --pull` refreshes the local copy.

Every build carries a signed provenance attestation, verifiable with the [GitHub CLI](https://cli.github.com):

```bash
gh attestation verify oci://ghcr.io/foo-coders/ubuntu-claude:latest -R foo-coders/msb-claude
```

### Building the image locally

To run your own changes to the image, or on a host the published image doesn't support (e.g. Apple Silicon), build it with Docker and load it straight into msb's local image cache:

```bash
docker build ubuntu-claude/ -t ubuntu-claude && docker save ubuntu-claude | msb load
```

`claude-msb` always uses the published image, so create the sandbox yourself, as in the next section, with `ubuntu-claude` as the image.

## Without the CLI

`claude-msb --new` boils down to this `msb create` (the example is for the project directory `~/projects/foo`; `claude-msb` also names the sandbox, adds the skills mount and the secrets described in [What a sandbox gets](#what-a-sandbox-gets)):

```bash
msb create \
  --name ubuntu-msb \
  --net public \
  -v ${PWD}:${PWD} \
  --workdir ${PWD} \
  --cpus 2 --max-cpus 8 \
  --memory 4G --max-memory 8G \
  --secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com" \
  --mount-owned /var/lib/docker:kind=disk,size=10G \
  ghcr.io/foo-coders/ubuntu-claude
```

- `--name ubuntu-msb` — name of the sandbox, used to find/reuse it (`msb exec`, `msb rm`, ...).
- `--net public` — allow all outbound network access. For a restricted setup, replace it with `--no-net` plus a `--net-rule "allow@api.anthropic.com:tcp:443"`.
- `-v ${PWD}:${PWD}` — bind-mount the current directory into the sandbox at the same path (use absolute path to avoid dynamic resolution change).
- `--workdir ${PWD}` — working directory inside the sandbox, aligned with the mount above.
- `--cpus 2 --max-cpus 8` / `--memory 4G --max-memory 8G` — baseline / burst resource limits.
- `--secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com"` — reads `$CLAUDE_CODE_OAUTH_TOKEN` from your host shell (export it first) and makes it available to the sandbox, scoped to `api.anthropic.com` only.
- `--mount-owned /var/lib/docker:kind=disk,size=10G` — the Docker disk.
- `ghcr.io/foo-coders/ubuntu-claude` — the image (or `ubuntu-claude` for a [local build](#building-the-image-locally)); `msb pull ghcr.io/foo-coders/ubuntu-claude` fetches it ahead of time.

Then attach to the sandbox, and remove it when you're done:

```bash
msb exec ubuntu-msb -- bash   # opens a shell; run `claude` from there
msb rm ubuntu-msb             # stops (if needed) and removes the sandbox and its state
```

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
msb rm <sandbox>                      # remove a sandbox (`claude-msb` prints its name when it creates it)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
