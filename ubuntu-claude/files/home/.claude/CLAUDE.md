## Dev tools

Dev tool and language runtime versions are managed with [mise](https://mise.jdx.dev), preinstalled and activated in this sandbox. Prefer `mise use -g <tool>@<version>` over `apt`, `nvm`, `pyenv`, or other manual installs whenever a command is missing (e.g. `mise use -g python@3.12`). Look up a tool's short name or available versions with `mise registry` / `mise ls-remote <tool>`.

## Git without SSH

This sandbox has no `ssh` binary, but `~/.gitconfig` rewrites GitHub SSH URLs (`git@github.com:...`, `ssh://git@github.com/...`) to HTTPS via `url.insteadOf`, and `gh` is git's HTTPS credential helper. So `git fetch`/`pull`/`push` on an SSH `origin` just work: keep `origin` as the single remote, unchanged. `git remote get-url` shows the rewritten HTTPS URL while `.git/config` keeps the SSH one; that's expected. SSH remotes on other hosts still fail.

**Auth failures** (`Invalid username or token`, `gh auth status` reporting an invalid token) usually mean the sandbox was created without its GitHub secret. With it, `msb` sets `GH_OAUTH_TOKEN` to the literal placeholder `$MSB_GH_OAUTH_TOKEN` and swaps in the real token on the wire. Check:

```
[ "$GH_OAUTH_TOKEN" = '$MSB_GH_OAUTH_TOKEN' ] && echo provided || echo missing
```

`missing` means the secret was never provided, and the fix is on the host: tell the user to recreate the sandbox with `claude-msb --replace --gh` (token in `~/.microsandbox/.env`), then retry.

## Docker

Docker CE is installed, but the daemon is not running at boot. Start it yourself when a task needs Docker:

```
sudo dockerd > /tmp/dockerd.log 2>&1 &
for _ in $(seq 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info --format '{{.ServerVersion}}'   # prints the version once the daemon is ready
```

`ubuntu` is in the `docker` group, so `docker` works without `sudo` once the daemon is up. Logs are in `/tmp/dockerd.log`.

**Prerequisite: an ext4 disk on `/var/lib/docker`.** The sandbox root is an overlayfs, and Docker's overlay storage can't be nested on top of it. Check with `findmnt /var/lib/docker`: it must show an `ext4` filesystem. If nothing is mounted there, `dockerd` still starts, but the first `docker run`/`docker build` fails with `mount source: "overlay" ... fstype: overlay ... err: invalid argument`. The fix is on the host, not in here: the sandbox has to be recreated with `--mount-owned /var/lib/docker:kind=disk,size=10G`. Tell the user instead of working around it.

**HTTPS from inside containers.** msb intercepts outbound TLS and re-signs it with its own CA (`/.msb/tls/ca.pem`). The sandbox trusts that CA, so `dockerd` image pulls work, but containers don't, so HTTPS from a container or a `RUN` build step fails with `certificate verify failed` / `server certificate not trusted`. Workarounds:

- `docker run`: mount the CA over the container's bundle, e.g. `-v /.msb/tls/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro` (path for Debian/Ubuntu/Alpine images).
- `docker build`: if the Dockerfile already has a build arg for an extra CA, pass msb's CA through it. Otherwise, add one with a conditional stage, before the steps that hit the network. The `base-with-ca` stage is only built when the arg is set, so builds without it are unchanged:

  ```dockerfile
  ARG EXTRA_CA_CERT=""

  FROM debian:trixie-slim AS base
  RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

  FROM base AS base-with-ca
  ARG EXTRA_CA_CERT
  RUN printf '%s\n' "$EXTRA_CA_CERT" > /usr/local/share/ca-certificates/extra-ca.crt && update-ca-certificates

  FROM base${EXTRA_CA_CERT:+-with-ca}
  # ... rest of the Dockerfile, now trusting the extra CA
  ```

  ```
  docker build --build-arg EXTRA_CA_CERT="$(cat /.msb/tls/ca.pem)" .
  ```

  `ARG`s declared in `base` must be redeclared after the last `FROM`. On Alpine, which has no `update-ca-certificates` by default, append the CA to `/etc/ssl/certs/ca-certificates.crt` instead. In a multi-stage build, repeat the pattern for each stage that hits the network. Keep this change local, and don't commit it to the project's Dockerfile unless the user asks.
