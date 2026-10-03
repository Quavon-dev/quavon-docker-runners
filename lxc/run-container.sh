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

# Per-runner caps so one heavy job can't starve its siblings. (Containers a
# job starts itself via the socket are bounded by the LXC limits instead.)
# Only applied when the LXC delegates the needed cgroup controllers to Docker.
limits=()
read -r can_cpu can_mem <<<"$(docker info --format '{{.CPUCfsQuota}} {{.MemoryLimit}}' 2>/dev/null || echo false false)"
if [[ -n "${RUNNER_CPUS:-}" ]]; then
  if [[ "$can_cpu" == true ]]; then limits+=(--cpus "$RUNNER_CPUS"); else echo "warning: CPU limits unsupported here, skipping" >&2; fi
fi
if [[ -n "${RUNNER_MEM:-}" ]]; then
  if [[ "$can_mem" == true ]]; then limits+=(--memory "${RUNNER_MEM}m" --memory-swap "${RUNNER_MEM}m"); else echo "warning: memory limits unsupported here, skipping" >&2; fi
fi

docker rm -f "gha-${name}" >/dev/null 2>&1 || true

# --network host  : service containers / published ports reachable on localhost (like hosted)
# same-path mount : job containers get valid host paths for _work and externals
# --rm            : every restart starts from the pristine image
docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || {
  echo "runner image $RUNNER_IMAGE not found - build it with: gha-runners build" >&2
  sleep 30; exit 1
}

# --pull never: the image is always built locally, never fetched from a registry
exec docker run --rm --init --pull never \
  --name "gha-${name}" \
  --network host \
  --user 1001:1001 \
  --group-add "$docker_gid" \
  --shm-size 2g \
  "${limits[@]}" \
  --env-file "$env_file" \
  "${token_env[@]}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${runner_dir}:${runner_dir}" \
  "$RUNNER_IMAGE"
