#!/usr/bin/env bash
# Quavon Docker Runners - one-command GitHub Actions runner LXC for Proxmox VE.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)"
#
# Creates a Debian LXC with Docker, registers N GitHub Actions runners using the
# registration token ("pair code") from GitHub, builds a runner image modeled on
# GitHub's hosted ubuntu-24.04 image and starts everything as systemd services.
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/quavon-dev/quavon-docker-runners.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
CT_REPO_DIR=/opt/quavon-docker-runners
APP="GitHub Docker Runners"
TITLE="Quavon ${APP}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# ---------------------------------------------------------------- ui helpers --
YW=$'\e[33m' GN=$'\e[1;92m' RD=$'\e[01;31m' BL=$'\e[36m' DIM=$'\e[2m' CL=$'\e[m'
msg_info()  { printf ' %s…%s %s\n' "$YW" "$CL" "$*"; }
msg_ok()    { printf ' %s✔%s %s\n' "$GN" "$CL" "$*"; }
msg_error() { printf ' %s✖ %s%s\n' "$RD" "$*" "$CL" >&2; }
die()       { msg_error "$*"; exit 1; }

header() {
  clear 2>/dev/null || true
  cat <<EOF
${BL}
   ____ _ _   _   _       _       ____
  / ___(_) |_| | | |_   _| |__   |  _ \\ _   _ _ __  _ __   ___ _ __ ___
 | |  _| | __| |_| | | | | '_ \\  | |_) | | | | '_ \\| '_ \\ / _ \\ '__/ __|
 | |_| | | |_|  _  | |_| | |_) | |  _ <| |_| | | | | | | |  __/ |  \\__ \\
  \\____|_|\\__|_| |_|\\__,_|_.__/  |_| \\_\\\\__,_|_| |_|_| |_|\\___|_|  |___/
${CL}${DIM}  Docker-based GitHub Actions runners in a Proxmox LXC - by Quavon${CL}

EOF
}

# whiptail wrappers; in NONINTERACTIVE=1 mode they return the default.
w_input() {   # w_input <text> <default>
  [[ "$NONINTERACTIVE" == 1 ]] && { echo "$2"; return; }
  whiptail --backtitle "$TITLE" --title "$APP" --inputbox "$1" 12 78 "$2" 3>&1 1>&2 2>&3 || exit_cancel
}
w_secret() {  # w_secret <text> <default>
  [[ "$NONINTERACTIVE" == 1 ]] && { echo "$2"; return; }
  whiptail --backtitle "$TITLE" --title "$APP" --passwordbox "$1" 12 78 3>&1 1>&2 2>&3 || exit_cancel
}
w_menu() {    # w_menu <text> <default> tag desc [tag desc ...]
  local text="$1" def="$2"; shift 2
  [[ "$NONINTERACTIVE" == 1 ]] && { echo "$def"; return; }
  whiptail --backtitle "$TITLE" --title "$APP" --default-item "$def" \
    --menu "$text" 18 78 8 "$@" 3>&1 1>&2 2>&3 || exit_cancel
}
w_yesno() {   # w_yesno <text> [default-yes:1|0]
  [[ "$NONINTERACTIVE" == 1 ]] && { [[ "${2:-1}" == 1 ]]; return; }
  whiptail --backtitle "$TITLE" --title "$APP" --yesno "$1" 14 78
}
exit_cancel() { clear 2>/dev/null || true; msg_error "Cancelled by user"; exit 130; }

# ------------------------------------------------------------- error cleanup --
CT_CREATED=0
BOOTSTRAP_TMP=""
on_error() {
  local rc=$?
  [[ "$rc" == 130 ]] || msg_error "Failed (exit ${rc}) at line $1"
}
# Runs on every exit (die, ERR, signals): wipe secrets, offer to drop a broken CT.
on_exit() {
  local rc=$?
  trap - EXIT ERR
  [[ -n "$BOOTSTRAP_TMP" ]] && rm -f "$BOOTSTRAP_TMP"
  if [[ "$rc" != 0 && "$CT_CREATED" == 1 ]]; then
    if w_yesno "Installation failed.\n\nDestroy the half-configured container ${CTID}?" 0; then
      pct stop "$CTID" >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge >/dev/null 2>&1 && msg_ok "Container ${CTID} destroyed"
    else
      msg_info "Container ${CTID} kept for debugging: pct enter ${CTID}"
    fi
  fi
  exit "$rc"
}
trap 'on_error $LINENO' ERR
trap on_exit EXIT

# ----------------------------------------------------------------- preflight --
preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox VE host."
  command -v pveversion >/dev/null || die "This script must run on a Proxmox VE host."
  for c in pct pveam pvesm pvesh whiptail; do command -v "$c" >/dev/null || die "missing command: $c"; done
  [[ "$(dpkg --print-architecture)" == amd64 ]] || die "Only amd64 Proxmox hosts are supported."
  local major; major="$(pveversion | grep -oP 'pve-manager/\K[0-9]+')"
  [[ "${major:-0}" -ge 8 ]] || die "Proxmox VE 8 or newer required (found: $(pveversion))."
}

# -------------------------------------------------------------- github input --
parse_pair_input() {   # prints "<url> <token>"
  local input="$1" url="" token=""
  if [[ "$input" =~ --url[[:space:]]+([^[:space:]]+) ]]; then url="${BASH_REMATCH[1]}"; fi
  if [[ "$input" =~ --token[[:space:]]+([^[:space:]]+) ]]; then token="${BASH_REMATCH[1]}"; fi
  [[ -z "$url" && "$input" =~ ^https:// ]] && url="${input%% *}"
  echo "${url%/} ${token}"
}
valid_url()   { [[ "$1" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]]; }
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_]{16,255}$ ]]; }
valid_name()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; }

ask_github() {
  local pasted url token
  pasted="$(w_input "GitHub > Settings > Actions > Runners > New self-hosted runner.

Paste the whole './config.sh --url ... --token ...' line
(or just the repo / org URL):" "${GH_URL:-}")"
  read -r url token <<<"$(parse_pair_input "$pasted")"
  valid_url "$url" || die "Invalid GitHub URL: '${url}' (expected https://github.com/<org>[/<repo>])"
  GH_URL="$url"
  GH_TOKEN="${token:-${GH_TOKEN:-}}"

  RUNNER_EPHEMERAL=0
  GH_PAT="${GH_PAT:-}"
  local mode
  mode="$(w_menu "Runner mode" "${RUNNER_MODE:-persistent}" \
    persistent "Pair code only. Workspace cleaned before each job (recommended)" \
    ephemeral  "Fresh container per job like GitHub-hosted. Needs a PAT")"
  if [[ "$mode" == ephemeral ]]; then
    RUNNER_EPHEMERAL=1
    [[ -n "$GH_PAT" ]] || GH_PAT="$(w_secret "Personal access token used to re-register after every job.

Fine-grained: repo 'Administration: write'
or org 'Self-hosted runners: write'." "")"
    [[ -n "$GH_PAT" ]] || die "Ephemeral mode requires a PAT."
  else
    [[ -n "$GH_TOKEN" ]] || GH_TOKEN="$(w_secret "Registration token (pair code) shown by GitHub after --token.
It is valid for 1 hour." "")"
    valid_token "$GH_TOKEN" || die "Registration token missing or invalid."
  fi
}

# ------------------------------------------------------------------ settings --
pick_storage() {   # pick_storage <content> <label>
  local content="$1" label="$2" items=() name type avail first=""
  while read -r name type _ _ _ avail _; do
    [[ -n "$name" ]] || continue
    first="${first:-$name}"
    items+=("$name" "$(printf '%-10s %6s GiB free' "$type" "$((avail / 1024 / 1024))")")
  done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active"')
  [[ ${#items[@]} -gt 0 ]] || die "No active storage supports '${content}'."
  if [[ ${#items[@]} -eq 2 ]]; then echo "$first"; return; fi
  w_menu "Storage for ${label}" "$first" "${items[@]}"
}

defaults() {
  CTID="${CTID:-$(pvesh get /cluster/nextid)}"
  CT_HOSTNAME="${CT_HOSTNAME:-gha-runners}"
  RUNNER_FLAVOR="${RUNNER_FLAVOR:-standard}"
  RUNNER_COUNT="${RUNNER_COUNT:-2}"
  RUNNER_LABELS="${RUNNER_LABELS:-docker}"
  RUNNER_GROUP="${RUNNER_GROUP:-}"
  CORES="${CORES:-4}"
  RAM="${RAM:-8192}"
  SWAP="${SWAP:-2048}"
  BRIDGE="${BRIDGE:-vmbr0}"
  NET_IP="${NET_IP:-dhcp}"
  NET_GW="${NET_GW:-}"
  VLAN="${VLAN:-}"
  UNPRIVILEGED="${UNPRIVILEGED:-1}"
  SSH_KEYS="${SSH_KEYS:-}"
}

flavor_disk() { [[ "$1" == full ]] && echo 100 || echo 40; }

ask_settings() {
  RUNNER_FLAVOR="$(w_menu "Runner image" "$RUNNER_FLAVOR" \
    standard "git, gh, Docker, Python, Node, build tools, kubectl, helm (~3 GB)" \
    full     "standard + Go, Java, .NET, Rust, PHP, Ruby, pwsh, browsers, clouds (~13 GB)")"
  DISK="${DISK:-$(flavor_disk "$RUNNER_FLAVOR")}"

  local mode
  mode="$(w_menu "Container settings" default \
    default  "CT ${CTID}, ${CORES} cores, ${RAM} MB RAM, ${DISK} GB disk, DHCP on ${BRIDGE}" \
    advanced "Choose everything yourself")"

  if [[ "$mode" == advanced ]]; then
    CTID="$(w_input "Container ID" "$CTID")"
    CT_HOSTNAME="$(w_input "Hostname" "$CT_HOSTNAME")"
    CORES="$(w_input "CPU cores" "$CORES")"
    RAM="$(w_input "RAM in MB" "$RAM")"
    SWAP="$(w_input "Swap in MB" "$SWAP")"
    DISK="$(w_input "Disk size in GB" "$DISK")"
    BRIDGE="$(w_input "Network bridge" "$BRIDGE")"
    NET_IP="$(w_input "IPv4: 'dhcp' or CIDR (e.g. 192.168.1.50/24)" "$NET_IP")"
    [[ "$NET_IP" != dhcp ]] && NET_GW="$(w_input "IPv4 gateway" "$NET_GW")"
    VLAN="$(w_input "VLAN tag (empty = none)" "$VLAN")"
    SSH_KEYS="$(w_input "Path to SSH public key file for root (empty = none)" "$SSH_KEYS")"
    w_yesno "Unprivileged container? (recommended)" 1 && UNPRIVILEGED=1 || UNPRIVILEGED=0
  fi

  RUNNER_COUNT="$(w_input "How many runners (parallel jobs)?" "$RUNNER_COUNT")"
  RUNNER_PREFIX="$(w_input "Runner name (suffix -1, -2, ... when more than one)" "${RUNNER_PREFIX:-$CT_HOSTNAME}")"
  RUNNER_LABELS="$(w_input "Extra labels, comma-separated (self-hosted,linux,x64 are automatic)" "$RUNNER_LABELS")"
  if [[ ! "$GH_URL" =~ ^https://[^/]+/[^/]+/[^/]+$ ]] || [[ "$GH_URL" == */enterprises/* ]]; then
    RUNNER_GROUP="$(w_input "Runner group (empty = Default)" "$RUNNER_GROUP")"
  fi

  ROOT_STORAGE="$(pick_storage rootdir "the container disk")"
  TMPL_STORAGE="$(pick_storage vztmpl "container templates")"

  validate_settings
}

validate_settings() {
  [[ "$CTID" =~ ^[0-9]+$ && "$CTID" -ge 100 ]] || die "Invalid container ID: $CTID"
  if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then die "ID $CTID is already in use"; fi
  valid_name "$CT_HOSTNAME" || die "Invalid hostname: $CT_HOSTNAME"
  valid_name "$RUNNER_PREFIX" || die "Invalid runner name: $RUNNER_PREFIX"
  local n
  for n in CORES RAM SWAP DISK RUNNER_COUNT; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || die "$n must be a number"
  done
  [[ "$RUNNER_COUNT" -ge 1 && "$RUNNER_COUNT" -le 32 ]] || die "Runner count must be 1-32"
  [[ "$RUNNER_LABELS" =~ ^[A-Za-z0-9._,-]*$ ]] || die "Labels may only contain A-Z a-z 0-9 . _ - ,"
  [[ "$NET_IP" == dhcp || "$NET_IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "Invalid IPv4: $NET_IP"
  [[ -z "$VLAN" || "$VLAN" =~ ^[0-9]+$ ]] || die "Invalid VLAN tag: $VLAN"
  [[ -z "$SSH_KEYS" || -f "$SSH_KEYS" ]] || die "SSH key file not found: $SSH_KEYS"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge $BRIDGE does not exist"
}

confirm() {
  local mode=persistent; [[ "$RUNNER_EPHEMERAL" == 1 ]] && mode=ephemeral
  w_yesno "Ready to create:

  Container   ${CTID} (${CT_HOSTNAME}) $([[ $UNPRIVILEGED == 1 ]] && echo unprivileged || echo privileged)
  Resources   ${CORES} cores, ${RAM} MB RAM, ${DISK} GB on ${ROOT_STORAGE}
  Network     ${BRIDGE} ${NET_IP}${VLAN:+ vlan ${VLAN}}
  GitHub      ${GH_URL}
  Runners     ${RUNNER_COUNT} x ${RUNNER_PREFIX} (${mode}, image: ${RUNNER_FLAVOR})
  Labels      self-hosted,linux,x64${RUNNER_LABELS:+,${RUNNER_LABELS}}

Continue?" 1 || exit_cancel
}

# ----------------------------------------------------------------- container --
ensure_template() {
  msg_info "Updating LXC template list"
  pveam update >/dev/null 2>&1 || true
  local available tmpl="" v
  available="$(pveam available --section system | awk '{print $2}')"
  for v in 13 12; do
    tmpl="$(awk -v p="^debian-${v}-standard" '$0 ~ p' <<<"$available" | sort -V | tail -n1)"
    [[ -n "$tmpl" ]] && break
  done
  [[ -n "$tmpl" ]] || die "No Debian 12/13 template available from pveam."
  if ! grep -qF "$tmpl" <<<"$(pveam list "$TMPL_STORAGE")"; then
    msg_info "Downloading template ${tmpl}"
    pveam download "$TMPL_STORAGE" "$tmpl" >/dev/null
  fi
  TEMPLATE="${TMPL_STORAGE}:vztmpl/${tmpl}"
  msg_ok "Template ${tmpl}"
}

create_ct() {
  local net="name=eth0,bridge=${BRIDGE},ip=${NET_IP}"
  [[ -n "$NET_GW" ]] && net+=",gw=${NET_GW}"
  [[ -n "$VLAN" ]] && net+=",tag=${VLAN}"

  local args=(
    --hostname "$CT_HOSTNAME"
    --cores "$CORES" --memory "$RAM" --swap "$SWAP"
    --rootfs "${ROOT_STORAGE}:${DISK}"
    --net0 "$net"
    --features "$([[ $UNPRIVILEGED == 1 ]] && echo nesting=1,keyctl=1,fuse=1 || echo nesting=1,fuse=1)"
    --unprivileged "$UNPRIVILEGED"
    --onboot 1 --start 0
    --ostype debian
    --timezone host
    --tags "github-runner;docker"
    --description "## ${APP}
Managed with \`gha-runners\` inside the container (\`pct enter ${CTID}\`).

GitHub: ${GH_URL}"
  )
  [[ -n "$SSH_KEYS" ]] && args+=(--ssh-public-keys "$SSH_KEYS")

  msg_info "Creating LXC ${CTID}"
  CT_CREATED=1   # set first: a half-finished create still gets cleaned up
  pct create "$CTID" "$TEMPLATE" "${args[@]}" >/dev/null
  msg_ok "Created LXC ${CTID}"
}

start_ct() {
  pct start "$CTID"
  msg_info "Waiting for network"
  pct exec "$CTID" -- bash -c 'for _ in $(seq 1 60); do getent hosts github.com >/dev/null && exit 0; sleep 2; done; exit 1' \
    || die "Container has no network/DNS (check bridge, DHCP, VLAN)."
  msg_ok "Network up ($(pct exec "$CTID" -- hostname -I | awk '{print $1}'))"
}

# Copy the repo into the CT: local checkout if we run from one, else git clone.
deploy_repo() {
  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  msg_info "Preparing base system"
  pct exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq dist-upgrade >/dev/null && apt-get install -y -qq git curl ca-certificates >/dev/null'
  if [[ -n "$src_dir" && -f "${src_dir}/lxc/setup.sh" ]]; then
    msg_info "Copying local checkout ${src_dir}"
    tar -C "$src_dir" -czf - . | pct exec "$CTID" -- bash -c "mkdir -p ${CT_REPO_DIR} && tar -xzf - -C ${CT_REPO_DIR}"
  else
    msg_info "Cloning ${REPO_URL} (${REPO_BRANCH})"
    pct exec "$CTID" -- git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CT_REPO_DIR"
  fi
  msg_ok "Scripts deployed to ${CT_REPO_DIR}"
}

install_docker() {
  msg_info "Installing Docker in the container"
  local rc=0
  pct exec "$CTID" -- bash "${CT_REPO_DIR}/lxc/setup.sh" docker || rc=$?
  if [[ "$rc" == 3 ]]; then
    msg_error "Docker cannot start containers in this LXC (usually AppArmor on nested containers)."
    w_yesno "Docker could not run a test container.

Common fix on Proxmox: run the LXC with an unconfined AppArmor profile
(lxc.apparmor.profile: unconfined). This lowers isolation between the
container and the host.

Apply the fix and retry?" 1 || die "Docker not working - aborted."
    pct stop "$CTID"
    echo "lxc.apparmor.profile: unconfined" >>"/etc/pve/lxc/${CTID}.conf"
    start_ct
    pct exec "$CTID" -- bash "${CT_REPO_DIR}/lxc/setup.sh" docker
  elif [[ "$rc" != 0 ]]; then
    return "$rc"
  fi
  msg_ok "Docker ready"
}

install_runners() {
  local tmp; tmp="$(mktemp)"
  BOOTSTRAP_TMP="$tmp"   # removed by on_exit even if pct push fails
  chmod 600 "$tmp"
  {
    printf 'GH_URL=%q\n' "$GH_URL"
    printf 'GH_TOKEN=%q\n' "${GH_TOKEN:-}"
    printf 'GH_PAT=%q\n' "${GH_PAT:-}"
    printf 'RUNNER_EPHEMERAL=%q\n' "$RUNNER_EPHEMERAL"
    printf 'RUNNER_PREFIX=%q\n' "$RUNNER_PREFIX"
    printf 'RUNNER_COUNT=%q\n' "$RUNNER_COUNT"
    printf 'RUNNER_LABELS=%q\n' "$RUNNER_LABELS"
    printf 'RUNNER_GROUP=%q\n' "$RUNNER_GROUP"
    printf 'RUNNER_FLAVOR=%q\n' "$RUNNER_FLAVOR"
  } >"$tmp"
  pct push "$CTID" "$tmp" /root/.gha-bootstrap.env --perms 600
  rm -f "$tmp"; BOOTSTRAP_TMP=""

  msg_info "Registering runners and building the '${RUNNER_FLAVOR}' image (this takes a while)"
  pct exec "$CTID" -- bash "${CT_REPO_DIR}/lxc/setup.sh" install /root/.gha-bootstrap.env
  msg_ok "Runners installed"
}

summary() {
  local ip; ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
  cat <<EOF

${GN}${APP} are online.${CL}

  Container : ${CTID} (${CT_HOSTNAME}) - ${ip}
  GitHub    : ${GH_URL}  (Settings > Actions > Runners)
  Use in workflows:
      runs-on: [self-hosted, linux${RUNNER_LABELS:+, ${RUNNER_LABELS//,/, }}]

  Manage (pct enter ${CTID}):
      gha-runners list | add | remove <name> | logs <name> -f | update

${YW}Security:${CL} jobs can use the Docker socket, i.e. they have root inside
this LXC. Do not attach these runners to public repositories that accept
pull requests from forks.
EOF
}

main() {
  # Running inside an existing installation = update it (helper-script convention).
  if ! command -v pveversion >/dev/null && command -v gha-runners >/dev/null; then
    exec gha-runners update
  fi
  header
  preflight
  defaults
  w_yesno "This will create a new LXC with Docker and GitHub Actions runners.\n\nProceed?" 1 || exit_cancel
  ask_github
  ask_settings
  confirm
  header
  ensure_template
  create_ct
  start_ct
  deploy_repo
  install_docker
  install_runners
  summary
}

main "$@"
