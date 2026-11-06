# AGENTS.md

## Contributing

Work is done when `mise run lint` passes: it runs the same tasks as CI.

Read `CONTRIBUTING.md` before opening a PR or touching `ubuntu-claude/Dockerfile`, `.github/workflows/`, `cli/claude-msb`, or a `mise.toml` task.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `foo-coders/msb-claude`, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created only when first needed. See `docs/agents/domain.md`.
