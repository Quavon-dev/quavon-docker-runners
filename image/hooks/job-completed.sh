#!/usr/bin/env bash
# Runs after every job: hand files created by container jobs back to the runner.
set -uo pipefail

[[ "${RUNNER_EPHEMERAL:-0}" == 1 ]] && exit 0
[[ -d "${RUNNER_DIR:-}/_work" ]] && sudo chown -R runner:runner "${RUNNER_DIR}/_work" 2>/dev/null
exit 0
