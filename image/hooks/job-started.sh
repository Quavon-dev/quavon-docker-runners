#!/usr/bin/env bash
# Runs before every job. Persistent runners keep state between jobs, so give
# each job a clean, runner-owned workspace like a fresh hosted VM would have.
set -uo pipefail

[[ "${RUNNER_EPHEMERAL:-0}" == 1 ]] && exit 0

work="${RUNNER_DIR:-}/_work"
[[ -d "$work" ]] || exit 0

# Container jobs write files as root; fix ownership so checkout never fails.
sudo chown -R runner:runner "$work" 2>/dev/null || true

# Default workspace layout is _work/<repo>/<repo>; use it if the hook env lacks GITHUB_WORKSPACE.
workspace="${GITHUB_WORKSPACE:-}"
if [[ -z "$workspace" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  repo="${GITHUB_REPOSITORY#*/}"
  workspace="${work}/${repo}/${repo}"
fi

if [[ -n "$workspace" && -d "$workspace" && "$workspace" == "$work"/* ]]; then
  echo "Cleaning workspace ${workspace}"
  sudo find "$workspace" -mindepth 1 -delete 2>/dev/null || true
fi
exit 0
