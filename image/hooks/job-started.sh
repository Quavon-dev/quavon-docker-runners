#!/usr/bin/env bash
# Runs before every job. Persistent runners keep state between jobs, so give
# each job a clean, runner-owned workspace like a fresh hosted VM would have.
set -uo pipefail

[[ -n "${RUNNER_DIR:-}" ]] || exit 0
work="${RUNNER_DIR}/_work"

leftovers="$(docker ps -aq \
  | xargs -r docker inspect -f '{{.Id}} {{index .Config.Labels "com.docker.compose.project.working_dir"}} {{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null \
  | awk -v w="${work}/" 'index($0, " " w) { print $1 }')"
if [[ -n "$leftovers" ]]; then
  echo "Removing $(wc -l <<<"$leftovers") container(s) left running by earlier jobs"
  xargs docker rm -f -v <<<"$leftovers" >/dev/null 2>&1 || true
fi

[[ "${RUNNER_EPHEMERAL:-0}" == 1 ]] && exit 0
[[ -d "$work" ]] || exit 0

# Container jobs write files as root; fix ownership so checkout never fails.
sudo find "$work" \( ! -user runner -o ! -group runner \) -exec chown -h runner:runner {} + 2>/dev/null || true

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
