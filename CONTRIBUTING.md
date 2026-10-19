# Contributing

## Running all checks

Every linter and formatter below is pinned via this repo's `mise.toml`/`mise.lock`. Run them all locally with:

```bash
mise run lint
```

This runs `lint:format`, `lint:github-action`, and `lint:docker`: the same tasks CI runs, as separate steps, on every pull request and every push to `main` (`.github/workflows/lint.yml`). A clean local run means a clean CI run.

## Formatting

Files are formatted with [prettier](https://prettier.io).

```bash
mise run format        # rewrite files in place
mise run lint:format   # check only (what CI runs)
```

## Linting GitHub Actions workflows

Workflows under `.github/` are checked by two tools:

- [actionlint](https://github.com/rhysd/actionlint): workflow correctness.
- [zizmor](https://docs.zizmor.sh): workflow security.

Run both with `mise run lint:github-action`, or each on its own with `mise run lint:actionlint` / `mise run lint:zizmor`.

### Ignoring a zizmor finding

Put an inline `# zizmor: ignore[RULE]` comment on the offending line. This is used for the in-house `foo-coders/github-actions` actions, which are deliberately referenced by their moving major tag (`@<action>/v1`) rather than a SHA:

```yaml
- uses: foo-coders/github-actions/actions/mise-update@mise-update/v1 # zizmor: ignore[unpinned-uses]
```

## Linting Dockerfiles

Dockerfiles are checked by two tools:

- [hadolint](https://github.com/hadolint/hadolint) — Dockerfile best practices and shellcheck of `RUN` commands.
- [trivy config](https://trivy.dev/latest/docs/scanner/misconfiguration/) — Dockerfile misconfiguration scanning. Any finding, at any severity, fails the run.

Run both locally with:

```bash
mise run lint:docker
```

Or each individually with `mise run lint:docker:hadolint` / `mise run lint:docker:trivy`.

This checks the Dockerfiles listed explicitly in the `lint:docker:hadolint` and `lint:docker:trivy` tasks (currently just `ubuntu-claude/Dockerfile`).

Adding a new Dockerfile to the repo? Add it to the `run` command of both the `lint:docker:hadolint` and `lint:docker:trivy` tasks in `mise.toml` — it isn't picked up automatically.

### Ignoring a rule

There's no `.hadolint.yaml`, `trivy.yaml`, or `.trivyignore` for this lint — rules are ignored per instruction, with an inline pragma directly above the instruction, immediately preceded by a comment explaining why:

```dockerfile
### DL3066: named user is intentional - sudoers, homedir, and ownership are all keyed to "ubuntu", not a numeric uid
# hadolint ignore=DL3066
USER ubuntu
```

One `### CODE: reason` line per ignored rule, directly above the pragma line, which must itself be the line immediately preceding the instruction — nothing else in between. Both tools only honor the comment line directly adjacent to the instruction, so:

- To ignore several hadolint rules on the same instruction, keep a single pragma with all codes comma-separated (`# hadolint ignore=CODE1,CODE2`).
- To ignore a trivy rule, use `# trivy:ignore:ID` (colon, not `=`), e.g. `# trivy:ignore:DS-0010`.
- To ignore rules from both tools on the same instruction, put both pragmas on that one line, hadolint first:

```dockerfile
### DL3004: sudo is intentional - this image grants the sandbox user passwordless sudo, that's the whole point of this image
### DS-0010: same reason as DL3004
# hadolint ignore=DL3004 # trivy:ignore:DS-0010
RUN sudo apt-get update ...
```

Trivy findings that aren't tied to a line (e.g. DS-0026, missing `HEALTHCHECK`) can't be ignored inline; address them in the Dockerfile itself (e.g. `HEALTHCHECK NONE` with a comment saying why).

## Scanning the image for vulnerabilities

This is separate from `lint:docker` above: `trivy config` checks the Dockerfile's source text for misconfigurations, while this scans the actual _built_ image for known CVEs in the OS packages it ends up with.

Run it locally with:

```bash
mise run image:scan
```

This builds the `ubuntu-claude` image, runs a single `trivy image` scan (all severities, saved as `trivy-results.json`), then reads that same file twice without rescanning:

- a CRITICAL+HIGH table, printed for visibility only. HIGH never fails the run: this image is a dev sandbox, not a minimal production image, and the unpinned `ubuntu` base drifts with new CVEs on its own schedule — failing on HIGH would turn CI red independently of any change here.
- a CRITICAL-only check (`trivy convert --exit-code 1`) — the only thing that can fail `image:scan`. CRITICAL still gates: worth a human look before merging.

In CI (`.github/workflows/scan-image.yml`), this runs on pull requests only — the image is rebuilt from scratch on every run and never pushed to a registry, so there's nothing persisted worth scanning on a schedule or after merge; the only thing worth catching is a PR introducing a new CRITICAL. The full `trivy-results.json` is uploaded as a build artifact on every run, including on failure, so CRITICAL/HIGH findings can be reviewed beyond the table in the log.

Publishing the image to a registry (and scanning what's actually distributed, on a schedule) is left for a future change.

### Ignoring a CVE

Create `.trivyignore` only when a specific CRITICAL finding needs suppressing (e.g. no fix available upstream yet), with a mandatory expiration date so it comes back for review instead of being silently suppressed forever:

```
# CVE-XXXX-YYYYY exp:2026-12-31 — reason this is accepted for now
CVE-XXXX-YYYYY
```

Trivy stops honoring the entry once `exp` passes.
