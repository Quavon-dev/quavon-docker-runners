#!/usr/bin/env bash
# Started by gha-runner@<name>.service. Runs one runner container in the
# foreground so systemd supervises it and journald captures its logs.
set -Eeuo pipefail

name="${1:?runner name required}"
CONF_DIR=/etc/gha-runners
env_file="${CONF_DIR}/runners/${name}.env"

[[ -f "$env_file" ]] || { echo "no config for runner '$name' ($env_file)" >&2; sleep 10; exit 1; }
# shellcheck source=/dev/null
source "${CONF_DIR}/config.env"

runner_dir="$(sed -n 's/^RUNNER_DIR=//p' "$env_file")"
[[ -d "$runner_dir" ]] || { echo "runner dir missing: $runner_dir" >&2; sleep 10; exit 1; }

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
limits=() parallel_env=()
read -r can_cpu can_mem <<<"$(docker info --format '{{.CPUCfsQuota}} {{.MemoryLimit}}' 2>/dev/null || echo false false)"
if [[ -n "${RUNNER_CPUS:-}" ]]; then
  if [[ "$can_cpu" == true ]]; then
    cpus="$(awk -v want="$RUNNER_CPUS" -v have="$(nproc)" 'BEGIN { print (want > have ? have : want) }')"
    workers="${cpus%.*}"; (( workers >= 1 )) || workers=1
    limits+=(--cpus "$cpus")
    parallel_env=(-e "GOMAXPROCS=$workers" -e "CARGO_BUILD_JOBS=$workers" -e "CMAKE_BUILD_PARALLEL_LEVEL=$workers"
                  -e "PYTEST_XDIST_AUTO_NUM_WORKERS=$workers")
  else
    echo "warning: CPU limits unsupported here, skipping" >&2
  fi
fi
if [[ -n "${RUNNER_MEM:-}" ]]; then
  if [[ "$can_mem" == true ]]; then limits+=(--memory "${RUNNER_MEM}m" --memory-swap "${RUNNER_MEM}m"); else echo "warning: memory limits unsupported here, skipping" >&2; fi
fi

# full-plus ships TigerBeetle, which needs io_uring. Docker's default seccomp
# profile refuses it, so those runners use the default profile plus the three
# io_uring calls (never unconfined). RUNNER_IO_URING=0 in config.env opts out.
security=()
seccomp_profile=/usr/local/lib/gha-runners/seccomp-io-uring.json
if [[ "${RUNNER_FLAVOR:-}" == full-plus && "${RUNNER_IO_URING:-1}" != 0 ]]; then
  if [[ -f "$seccomp_profile" ]]; then security+=(--security-opt "seccomp=${seccomp_profile}")
  else echo "warning: ${seccomp_profile} missing, io_uring stays blocked (run: gha-runners update)" >&2; fi
fi

docker rm -f "gha-${name}" >/dev/null 2>&1 || true
# A container Docker lost track of (e.g. on a full disk) can leave its
# endpoint in the host network behind and block every new start.
docker network disconnect -f host "gha-${name}" >/dev/null 2>&1 || true

# --network host  : service containers / published ports reachable on localhost (like hosted)
# same-path mount : job containers get valid host paths for _work and externals
# --rm            : every restart starts from the pristine image
docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || {
  echo "runner image $RUNNER_IMAGE not found - build it with: gha-runners build" >&2
  sleep 30; exit 1
}

# Docker sometimes keeps a removed container's name reserved, and only a
# daemon restart frees it. Restart it after a few failed starts, but not
# while another runner is in the middle of a job.
stale_name_recovery() {
  local count_file="/run/gha-runners/${name}.start-conflicts" count busy
  install -d /run/gha-runners
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  echo "$count" >"$count_file"
  (( count >= 5 )) || return 0
  busy="$(find /srv/gha-runners -mindepth 2 -maxdepth 2 -name .gha-job-running 2>/dev/null | head -1)"
  if [[ -n "$busy" ]]; then
    echo "Docker still holds the name gha-${name}; waiting for running jobs before restarting Docker" >&2
    return 0
  fi
  echo "Docker still holds the name gha-${name} after ${count} tries: restarting Docker" >&2
  rm -f "$count_file"
  systemctl --no-block restart docker.service
}

# --pull never: the image is always built locally, never fetched from a registry
create_err="$(mktemp)"
if ! id="$(docker create --rm --init --pull never \
  --name "gha-${name}" \
  --network host \
  --user 1001:1001 \
  --group-add "$docker_gid" \
  --shm-size 2g \
  "${limits[@]}" \
  "${parallel_env[@]}" \
  "${security[@]}" \
  --env-file "$env_file" \
  "${token_env[@]}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${runner_dir}:${runner_dir}" \
  "$RUNNER_IMAGE" 2>"$create_err")"; then
  cat "$create_err" >&2
  grep -qE 'is already in use|already exists' "$create_err" && stale_name_recovery
  rm -f "$create_err"
  sleep 5; exit 1
fi
cat "$create_err" >&2; rm -f "$create_err"
rm -f "/run/gha-runners/${name}.start-conflicts"
unset RUNNER_TOKEN
exec docker start --attach "$id"
