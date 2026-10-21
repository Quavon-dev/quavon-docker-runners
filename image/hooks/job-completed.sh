#!/usr/bin/env bash
# Runs after every job: hand files created by container jobs back to the runner.
set -uo pipefail

[[ -n "${RUNNER_DIR:-}" ]] || exit 0
rm -f "${RUNNER_DIR}/.gha-job-running"

[[ "${RUNNER_EPHEMERAL:-0}" == 1 ]] && exit 0
[[ -d "${RUNNER_DIR}/_work" ]] \
  && sudo find "${RUNNER_DIR}/_work" \( ! -user runner -o ! -group runner \) -exec chown -h runner:runner {} + 2>/dev/null
exit 0
