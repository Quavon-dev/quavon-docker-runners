#!/usr/bin/env bash
# Started by gha-runner@<name>.service. Runs one runner container in the
# foreground so systemd supervises it and journald captures its logs.
set -Eeuo pipefail

name="${1:?runner name required}"
CONF_DIR=/etc/gha-runners
env_file="${CONF_DIR}/runners/${name}.env"

[[ -f "$env_file" ]] || { echo "no config for runner '$name' ($env_file)" >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONF_DIR}/config.env"

runner_dir="$(sed -n 's/^RUNNER_DIR=//p' "$env_file")"
[[ -d "$runner_dir" ]] || { echo "runner dir missing: $runner_dir" >&2; exit 1; }

docker_gid="$(stat -c %g /var/run/docker.sock)"

# Ephemeral runners re-register on every start. Only the short-lived
# registration token is passed in; the PAT stays on the LXC.
token_env=()
if [[ "$(sed -n 's/^RUNNER_EPHEMERAL=//p' "$env_file")" == 1 ]]; then
  if ! token="$(/usr/local/bin/gha-runners _regtoken "$name")" || [[ -z "$token" ]]; then
    echo "could not get a registration token for '$name' (PAT revoked/expired?) - retrying in 60s" >&2
    sleep 60
    exit 1
  fi
  export RUNNER_TOKEN="$token"
  token_env=(-e RUNNER_TOKEN)
fi

docker rm -f "gha-${name}" >/dev/null 2>&1 || true

# --network host  : service containers / published ports reachable on localhost (like hosted)
# same-path mount : job containers get valid host paths for _work and externals
# --rm            : every restart starts from the pristine image
exec docker run --rm --init \
  --name "gha-${name}" \
  --network host \
  --user 1001:1001 \
  --group-add "$docker_gid" \
  --shm-size 2g \
  --env-file "$env_file" \
  "${token_env[@]}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${runner_dir}:${runner_dir}" \
  "$RUNNER_IMAGE"
