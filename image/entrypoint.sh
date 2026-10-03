#!/usr/bin/env bash
# Container entrypoint: (re)registers when ephemeral, then runs the runner.
#
# Required env:  RUNNER_DIR  GITHUB_URL  RUNNER_NAME
# Optional env:  RUNNER_LABELS  RUNNER_GROUP  RUNNER_EPHEMERAL=1 + RUNNER_TOKEN
set -Eeuo pipefail

die() { echo "entrypoint: $*" >&2; exit 1; }

: "${RUNNER_DIR:?RUNNER_DIR is required}"
: "${GITHUB_URL:?GITHUB_URL is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"

# Toolchain env produced at image build time (PATH, JAVA_HOME, ImageOS ...).
# shellcheck source=/dev/null
source /etc/gha/env.sh

cd "$RUNNER_DIR" || die "runner dir $RUNNER_DIR not mounted"
[[ -x ./run.sh ]] || die "runner binaries missing in $RUNNER_DIR (run 'gha-runners add' on the LXC)"

if [[ "${RUNNER_EPHEMERAL:-0}" == 1 ]]; then
  [[ -n "${RUNNER_TOKEN:-}" ]] || die "ephemeral mode needs RUNNER_TOKEN"
  echo "entrypoint: ephemeral mode - fresh workspace + registration"
  rm -f .runner .credentials .credentials_rsaparams
  if [[ -d _work ]]; then sudo rm -rf _work; fi
  args=(--unattended --replace --ephemeral --url "$GITHUB_URL" --name "$RUNNER_NAME" --work _work)
  [[ -n "${RUNNER_LABELS:-}" ]] && args+=(--labels "$RUNNER_LABELS")
  [[ -n "${RUNNER_GROUP:-}" ]] && args+=(--runnergroup "$RUNNER_GROUP")
  if ! ACTIONS_RUNNER_INPUT_TOKEN="$RUNNER_TOKEN" ./config.sh "${args[@]}"; then
    sleep 30   # avoid hammering the API from systemd's restart loop
    die "registration failed"
  fi
fi

# Never leak credentials into job steps (they inherit this environment).
unset RUNNER_TOKEN

[[ -f .runner ]] || die "runner is not registered - run 'gha-runners add' on the LXC"

# Re-capture PATH and toolchain vars from *this* image for job steps.
rm -f .env .path
./env.sh >/dev/null

exec ./run.sh
