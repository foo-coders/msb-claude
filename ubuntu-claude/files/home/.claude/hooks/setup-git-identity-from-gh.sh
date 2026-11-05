#!/usr/bin/env bash

# SessionStart hook: ensure the git user.name/user.email are set, configuring
# them from the authenticated gh account if not.
# - If both are already set, report them and exit.
# - Otherwise fetch name/email from `gh api user`, falling back to login for a
#   missing name and to the GitHub noreply address for a missing email, then
#   apply whichever of user.name/user.email was still unset with
#   `git config --global`.
# - If `gh api user` fails, or a usable name/email still can't be resolved,
#   warn (short systemMessage for the user, additionalContext telling Claude
#   not to invent an identity) and leave git to fail on its own at commit time.
#
# Never exits non-zero: this used to be a PreToolUse hook that blocked on
# failure, but its `if: Bash(git commit *)` filter also matches any command
# Claude Code can't statically parse (e.g. `echo $(true)`), so it ended up
# blocking unrelated Bash calls whenever gh wasn't authenticated.

set -euo pipefail

# Print the hook's JSON output.
#   $1: message shown to the user (systemMessage)
#   $2: optional, text added to Claude's context (additionalContext)
emit() {
  jq -n --arg msg "$1" --arg ctx "${2:-}" '{
    systemMessage: $msg,
    hookSpecificOutput: (
      if $ctx == "" then null
      else { hookEventName: "SessionStart", additionalContext: $ctx }
      end
    )
  } | with_entries(select(.value != null))'
}

# Report that the identity could not be set up, then exit 0 (never blocks).
#   $1: why, e.g. gh's error message
warn_exit() {
  emit "git identity not set: $1" \
    "git user.name/user.email are not set and could not be configured from \`gh api user\` ($1), so \`git commit\` will fail. Don't invent an identity: ask the user to set one (\`git config --global user.name/user.email\`)."
  exit 0
}

# Report the identity in use, then exit 0.
#   $1: how it was obtained, e.g. "already set" or "set from gh"
#   $2: name, $3: email
success_exit() {
  emit "git identity $1: $2 <$3>"
  exit 0
}

existing_git_name=$(git config user.name || true)
existing_git_email=$(git config user.email || true)

if [[ -n "$existing_git_name" && -n "$existing_git_email" ]]; then
  success_exit "already set" "$existing_git_name" "$existing_git_email"
fi

git_name=$existing_git_name
git_email=$existing_git_email

gh_err=$(mktemp)
trap 'rm -f "$gh_err"' EXIT
if ! gh_user=$(gh api user 2>"$gh_err"); then
  warn_exit "$(tr '\n' ' ' <"$gh_err" | sed 's/ *$//')"
fi

gh_login=$(jq -r '.login' <<<"$gh_user")
gh_id=$(jq -r '.id' <<<"$gh_user")
gh_name=$(jq -r '.name' <<<"$gh_user")
gh_email=$(jq -r '.email' <<<"$gh_user")

if [[ -z "$git_name" ]]; then
  git_name=$gh_name
  if [[ -z "$git_name" || "$git_name" == "null" ]]; then
    git_name="$gh_login"
    if [[ -z "$git_name" || "$git_name" == "null" ]]; then
      warn_exit "no usable name from gh"
    fi
  fi
fi

if [[ -z "$git_email" ]]; then
  git_email=$gh_email
  if [[ -z "$git_email" || "$git_email" == "null" ]]; then
    if [[ -z "$gh_login" || "$gh_login" == "null" || -z "$gh_id" || "$gh_id" == "null" ]]; then
      warn_exit "no usable email from gh"
    fi
    git_email="${gh_id}+${gh_login}@users.noreply.github.com"
  fi
fi

if [[ -z "$existing_git_name" ]]; then
  git config --global user.name "$git_name"
fi
if [[ -z "$existing_git_email" ]]; then
  git config --global user.email "$git_email"
fi
success_exit "set from gh" "$git_name" "$git_email"
