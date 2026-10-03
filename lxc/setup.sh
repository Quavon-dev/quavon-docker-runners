#!/usr/bin/env bash
# Provisioning inside the LXC. Called by install.sh on the Proxmox host.
#
#   setup.sh docker            install Docker Engine and verify it can run containers
#   setup.sh files             (re)install CLI + systemd units from this repo
#   setup.sh register <envfile> register runners from the bootstrap file (phase 1)
#   setup.sh start             build the image if missing, start all runners (phase 2)
#   setup.sh install <envfile> both phases
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONF_DIR=/etc/gha-runners
LIB_DIR=/usr/local/lib/gha-runners
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n\e[36m==>\e[0m %s\n' "$*"; }
die() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

setup_docker() {
  log "Installing Docker Engine"
  apt-get update -qq
  apt-get install -y --no-install-recommends ca-certificates curl gnupg jq git sudo
  . /etc/os-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  install -d /etc/docker
  [[ -f /etc/docker/daemon.json ]] || cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
EOF
  systemctl enable docker >/dev/null
  systemctl restart docker

  log "Verifying Docker can run containers"
  docker pull -q hello-world >/dev/null || die "cannot pull images - check DNS/proxy/internet in the LXC"
  local out
  if ! out="$(docker run --rm hello-world 2>&1)"; then
    echo "$out" >&2
    exit 3   # runtime failure: install.sh offers the AppArmor fallback
  fi
  echo "Docker OK - storage driver: $(docker info --format '{{.Driver}}')"
}

setup_files() {
  log "Installing gha-runners CLI and systemd units"
  install -d "$LIB_DIR" "$CONF_DIR" /srv/gha-runners
  install -m 0755 "${REPO_DIR}/lxc/run-container.sh" "${LIB_DIR}/run-container.sh"
  install -m 0755 "${REPO_DIR}/lxc/gha-runners" /usr/local/bin/gha-runners
  install -m 0644 "${REPO_DIR}"/lxc/systemd/* /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now gha-runners-prune.timer >/dev/null
}

ensure_runner_user() {
  # Same uid as inside the image so bind-mounted files line up.
  id runner >/dev/null 2>&1 || useradd -m -u 1001 -U -s /bin/bash runner
  # Runner (.NET) runtime deps for registering from the LXC itself.
  apt-get install -y --no-install-recommends libicu-dev libkrb5-3 zlib1g >/dev/null
}

write_config() {   # write_config <flavor> <labels> <cpus> <mem MB>
  {
    printf 'REPO_DIR=%q\n' "$REPO_DIR"
    printf 'RUNNER_FLAVOR=%q\n' "$1"
    printf 'RUNNER_IMAGE=%q\n' "quavon/gha-runner:$1"
    printf 'DEFAULT_LABELS=%q\n' "$2"
    printf 'RUNNER_CPUS=%q\n' "${3:-}"
    printf 'RUNNER_MEM=%q\n' "${4:-}"
  } >"${CONF_DIR}/config.env"
}

# Phase 1: register runners (tokens expire after 1 hour - do this first).
setup_register() {
  local bootstrap="${1:?bootstrap env file required}"
  [[ -f "$bootstrap" ]] || die "bootstrap file $bootstrap not found"
  # shellcheck source=/dev/null
  source "$bootstrap"
  rm -f "$bootstrap"   # contains the token - never keep it on disk

  : "${GH_URL:?}" "${RUNNER_PREFIX:?}" "${RUNNER_COUNT:?}" "${RUNNER_FLAVOR:?}"

  setup_files
  ensure_runner_user
  write_config "$RUNNER_FLAVOR" "${RUNNER_LABELS:-}" "${RUNNER_CPUS:-}" "${RUNNER_MEM:-}"

  # Re-runs (e.g. after a name clash) only add the runners still missing.
  local i name args have
  have=0
  if [[ -d "${CONF_DIR}/runners" ]]; then
    have="$(find "${CONF_DIR}/runners" -name '*.env' | wc -l)"
  fi
  for ((i = have + 1; i <= RUNNER_COUNT; i++)); do
    name="$RUNNER_PREFIX"; [[ "$RUNNER_COUNT" -gt 1 ]] && name="${RUNNER_PREFIX}-${i}"
    log "Configuring runner ${name}"
    args=(--name "$name" --url "$GH_URL" --labels "${RUNNER_LABELS:-}" --no-start)
    [[ -n "${RUNNER_GROUP:-}" ]] && args+=(--group "$RUNNER_GROUP")
    [[ "${RUNNER_EPHEMERAL:-0}" == 1 ]] && args+=(--ephemeral)
    # Secrets via env, not argv (keeps them out of `ps`).
    # exit 4 = name already taken in GitHub; install.sh asks for another name
    GHA_TOKEN="${GH_TOKEN:-}" GHA_PAT="${GH_PAT:-}" gha-runners add "${args[@]}"
  done
}

# Phase 2: make sure the image exists, then start every configured runner.
setup_start() {
  # shellcheck source=/dev/null
  source "${CONF_DIR}/config.env"
  docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || gha-runners build --flavor "$RUNNER_FLAVOR"
  local f name
  for f in "${CONF_DIR}"/runners/*.env; do
    [[ -e "$f" ]] || continue
    name="${f##*/}"; name="${name%.env}"
    systemctl enable --now "gha-runner@${name}.service"
  done
  sleep 5
  gha-runners list
}

case "${1:-}" in
  docker) setup_docker ;;
  files) setup_files ;;
  register) setup_register "${2:-}" ;;
  start) setup_start ;;
  install) setup_register "${2:-}"; setup_start ;;
  *) die "usage: setup.sh docker|files|register <envfile>|start|install <envfile>" ;;
esac
