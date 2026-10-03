#!/usr/bin/env bash
# Quavon Docker Runners - one-command GitHub Actions runner LXC for Proxmox VE.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)"
#
# Creates a Debian LXC with Docker, registers N GitHub Actions runners using the
# registration token ("pair code") from GitHub, builds a runner image modeled on
# GitHub's hosted ubuntu-24.04 image and starts everything as systemd services.
set -Eeuo pipefail
shopt -s inherit_errexit

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
w_msg() {     # w_msg <text> [height]
  [[ "$NONINTERACTIVE" == 1 ]] && return 0
  whiptail --backtitle "$TITLE" --title "$APP" --msgbox "$1" "${2:-14}" 78
}
exit_cancel() { clear 2>/dev/null || true; msg_error "Cancelled by user"; exit 130; }

# Ask until the value passes <validator>; invalid input re-opens the prompt
# with an explanation instead of aborting. Optional <normalizer> cleans input first.
w_ask() {     # w_ask <text> <default> <validator> <hint> [normalizer]
  local text="$1" value="$2" validator="$3" hint="$4" norm="${5:-}"
  while true; do
    value="$(w_input "$text" "$value")" || exit 130
    [[ -n "$norm" ]] && value="$("$norm" "$value")"
    if "$validator" "$value"; then echo "$value"; return 0; fi
    [[ "$NONINTERACTIVE" == 1 ]] && die "${hint} (got: '${value}')"
    w_msg "That value can't be used:

  '${value}'

${hint}" 16
  done
}

# ------------------------------------------------------------- error cleanup --
CREATED_CTS=()
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
  if [[ "$rc" != 0 && ${#CREATED_CTS[@]} -gt 0 ]]; then
    if w_yesno "Installation failed.\n\nDestroy the container(s) created by this run: ${CREATED_CTS[*]}?" 0; then
      local id
      for id in "${CREATED_CTS[@]}"; do
        pct stop "$id" >/dev/null 2>&1 || true
        pct destroy "$id" --purge >/dev/null 2>&1 && msg_ok "Container ${id} destroyed"
      done
    else
      msg_info "Kept for debugging: ${CREATED_CTS[*]} (pct enter <id>)"
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
valid_posint() { [[ "$1" =~ ^[1-9][0-9]{0,6}$ ]]; }
valid_count() { valid_posint "$1" && (( $1 <= 32 )); }
valid_ipv4()  {
  local a b c d
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$1"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}
valid_net_ip() { [[ "$1" == dhcp ]] || { valid_ipv4 "${1%/*}" && [[ "$1" =~ /([0-9]|[12][0-9]|3[0-2])$ ]]; }; }
valid_gw()    { [[ -z "$1" ]] || valid_ipv4 "$1"; }
valid_vlan()  { [[ -z "$1" ]] || { valid_posint "$1" && (( $1 <= 4094 )); }; }
valid_sshkey() { [[ -z "$1" || -f "$1" ]]; }
valid_bridge() { [[ -n "$1" ]] && ip link show "$1" >/dev/null 2>&1; }
valid_lan_allow() {
  local item
  [[ -z "$1" ]] && return 0
  IFS=',' read -ra _items <<<"$1"
  for item in "${_items[@]}"; do
    valid_ipv4 "${item%/*}" || return 1
    [[ "$item" != */* || "$item" =~ /([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  done
}
valid_dns() {
  local d
  [[ -n "$1" ]] || return 1
  for d in $1; do
    valid_ipv4 "$d" || return 1
    [[ "$NET_ISOLATION" == internet ]] && is_private_ip "$d" && return 1
  done
  return 0
}
valid_labels() {
  local l
  [[ -z "$1" ]] && return 0
  IFS=',' read -ra _items <<<"$1"
  for l in "${_items[@]}"; do [[ "$l" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1; done
}
valid_ctid() {
  valid_posint "$1" && (( $1 >= 100 && $1 <= 999999999 )) || return 1
  ! id_in_use "$1"
}
valid_any() { return 0; }
# Hostname must be valid and, with its -1/-2 suffixes, unused on this host.
valid_free_hostname() {
  valid_name "$1" || return 1
  local taken; taken=" $(all_ct_hostnames | tr '\n' ' ') "
  [[ "$taken" != *" $1 "* && "$taken" != *" $1-1 "* ]]
}

# "docker, GPU ,docker,,self-hosted" -> "docker,GPU": strips whitespace, empty
# entries, duplicates and the labels GitHub adds by itself.
normalize_labels() {
  local l out=() seen=","
  IFS=',' read -ra _items <<<"${1//[[:space:]]/}"
  for l in "${_items[@]}"; do
    [[ -z "$l" ]] && continue
    case "${l,,}" in self-hosted|linux|x64) continue ;; esac
    [[ "$seen" == *",${l,,},"* ]] && continue
    seen+="${l,,},"; out+=("$l")
  done
  (IFS=,; echo "${out[*]}")
}
normalize_csv() { local v="${1//[[:space:]]/}"; v="${v#,}"; echo "${v%,}"; }
normalize_trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; echo "${v%"${v##*[![:space:]]}"}"; }

ask_github() {
  local pasted="${GH_URL:-}" url token
  while true; do
    pasted="$(w_input "GitHub > Settings > Actions > Runners > New self-hosted runner.

Paste the whole './config.sh --url ... --token ...' line
(or just the repo / org URL):" "$pasted")" || exit 130
    read -r url token <<<"$(parse_pair_input "$pasted")"
    valid_url "$url" && break
    [[ "$NONINTERACTIVE" == 1 ]] && die "Invalid GitHub URL: '${url}'"
    w_msg "Could not find a GitHub URL in what you pasted.

Expected one of:
  ./config.sh --url https://github.com/<org>/<repo> --token <TOKEN>
  https://github.com/<org>              (organisation)
  https://github.com/<org>/<repo>       (repository)
  https://github.com/enterprises/<ent>  (enterprise)" 16
  done
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
    while [[ -z "$GH_PAT" ]]; do
      GH_PAT="$(w_secret "Personal access token used to re-register after every job.

Fine-grained: repo 'Administration: write'
or org 'Self-hosted runners: write'." "")" || exit 130
      [[ -n "$GH_PAT" ]] || { [[ "$NONINTERACTIVE" == 1 ]] && die "Ephemeral mode requires GH_PAT."; w_msg "Ephemeral mode needs a PAT."; }
    done
  else
    while ! valid_token "${GH_TOKEN:-}"; do
      [[ "$NONINTERACTIVE" == 1 ]] && die "Registration token (GH_TOKEN) missing or invalid."
      [[ -n "${GH_TOKEN:-}" ]] && w_msg "That doesn't look like a registration token (letters and digits only, 16+ characters)."
      GH_TOKEN="$(w_secret "Registration token (pair code) shown by GitHub after --token.
It is valid for 1 hour." "")" || exit 130
      GH_TOKEN="$(normalize_trim "$GH_TOKEN")"
    done
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

id_in_use() { pct status "$1" >/dev/null 2>&1 || qm status "$1" >/dev/null 2>&1; }

next_free_id() {   # next_free_id <start>
  local id="$1"
  while id_in_use "$id"; do id=$((id + 1)); done
  echo "$id"
}

# Existing LXCs created by this installer (tagged github-runner): "<id> <hostname>"
existing_runner_cts() {
  local id
  for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    pct config "$id" 2>/dev/null | grep -qE '^tags:.*github-runner' || continue
    echo "$id $(pct config "$id" | awk '/^hostname:/ {print $2}')"
  done
}

all_ct_hostnames() {
  local id
  for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    pct config "$id" 2>/dev/null | awk '/^hostname:/ {print $2}'
  done
}

# First of gha-runners, gha-runners-2, ... not used by any container on this host.
unique_hostname() {   # unique_hostname <base>
  local base="$1" name="$1" n=2 taken
  taken=" $(all_ct_hostnames | tr '\n' ' ') "
  while [[ "$taken" == *" ${name} "* || "$taken" == *" ${name}-1 "* ]]; do
    name="${base}-${n}"; n=$((n + 1))
  done
  echo "$name"
}

# The "check": tell the user about runner LXCs already on this host, because
# adding runners there may be what they actually want.
check_existing() {
  local existing
  existing="$(existing_runner_cts)"
  [[ -z "$existing" ]] && return 0
  w_yesno "This host already has GitHub runner container(s):

    CT ${existing//$'\n'/$'\n'    CT }

Continuing creates ADDITIONAL container(s) with new, unique names.

To add runners to an existing container instead, cancel and run:
    pct enter <CT>    then    gha-runners add

Create new container(s)?" 1 || exit_cancel
}

defaults() {
  CTID="${CTID:-$(pvesh get /cluster/nextid)}"
  CT_HOSTNAME="${CT_HOSTNAME:-$(unique_hostname gha-runners)}"
  RUNNER_FLAVOR="${RUNNER_FLAVOR:-standard}"
  RUNNER_COUNT="${RUNNER_COUNT:-2}"
  LAYOUT="${LAYOUT:-shared}"
  RUNNER_LABELS="${RUNNER_LABELS:-docker}"
  RUNNER_GROUP="${RUNNER_GROUP:-}"
  BRIDGE="${BRIDGE:-vmbr0}"
  NET_IP="${NET_IP:-dhcp}"
  NET_GW="${NET_GW:-}"
  VLAN="${VLAN:-}"
  UNPRIVILEGED="${UNPRIVILEGED:-1}"
  SSH_KEYS="${SSH_KEYS:-}"
  NET_ISOLATION="${NET_ISOLATION:-internet}"
  DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9}"
  LAN_ALLOW="${LAN_ALLOW:-}"
}

# Per-runner size presets: "<cpus> <ram MB> <job disk GB>".
# Each runner container is capped at cpus/ram; the LXC gets the sum + 1 GB RAM
# for the OS. Job disk = room for images/caches pulled by jobs (pruned daily).
declare -A SIZE_PRESETS=(
  [small]="1 2048 4"
  [medium]="2 4096 6"
  [large]="4 8192 10"
  [xlarge]="8 16384 20"
)

host_cpus()   { nproc; }
host_ram_mb() { awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo; }

# How many runners and how they are spread over containers.
ask_parallel() {
  RUNNER_COUNT="$(w_ask "How many jobs should be able to run AT THE SAME TIME?

A runner executes exactly one job at a time, so this is the number of
runners. Jobs beyond that wait in GitHub's queue until a runner is free.
Example: 3 = up to 3 jobs (e.g. build, test, lint) in parallel." \
    "$RUNNER_COUNT" valid_count "Enter a whole number from 1 to 32.")"

  if (( RUNNER_COUNT == 1 )); then LAYOUT=shared; return 0; fi

  LAYOUT="$(w_menu "Where should the ${RUNNER_COUNT} runners live?

shared   : 1 container, ${RUNNER_COUNT} runners. They share Docker, disk and the
           image. Least overhead. A job could see/affect the other runners.
separate : ${RUNNER_COUNT} containers, 1 runner each. Jobs fully isolated from each
           other, each with its own firewall. ~0.5 GB RAM + one image copy
           (~3/13 GB disk) extra per container." "$LAYOUT" \
    shared   "1 LXC with ${RUNNER_COUNT} runners (trusted repos, recommended)" \
    separate "${RUNNER_COUNT} LXCs with 1 runner each (untrusted / mixed repos)")"
}

runners_per_ct() { [[ "$LAYOUT" == separate ]] && echo 1 || echo "$RUNNER_COUNT"; }
ct_count()       { [[ "$LAYOUT" == separate ]] && echo "$RUNNER_COUNT" || echo 1; }

ask_size() {
  SIZE="$(w_menu "Resources PER RUNNER (each runner is capped at this)
${RUNNER_COUNT} runner(s) in $(ct_count) container(s). Host: $(host_cpus) CPUs, $(( $(host_ram_mb) / 1024 )) GB RAM" "${SIZE:-medium}" \
    small  "1 CPU,  2 GB RAM  - lint, unit tests, small builds" \
    medium "2 CPU,  4 GB RAM  - typical web/app builds (recommended)" \
    large  "4 CPU,  8 GB RAM  - Docker image builds, big test suites" \
    xlarge "8 CPU, 16 GB RAM  - heavy compiles (Rust, C++, Android)" \
    custom "Set CPU and RAM per runner yourself")"

  local job_disk
  if [[ "$SIZE" == custom ]]; then
    RUNNER_CPUS="$(w_ask "CPU cores per runner" "${RUNNER_CPUS:-2}" valid_posint "Enter a whole number, e.g. 2.")"
    RUNNER_MEM="$(w_ask "RAM per runner in MB (1024 = 1 GB)" "${RUNNER_MEM:-4096}" valid_posint "Enter a whole number of MB, e.g. 4096.")"
    job_disk="$(w_ask "Disk per runner for job images/caches in GB" "8" valid_posint "Enter a whole number of GB, e.g. 8.")"
  else
    [[ -n "${SIZE_PRESETS[$SIZE]:-}" ]] || die "Unknown size '$SIZE' (small|medium|large|xlarge|custom)"
    read -r RUNNER_CPUS RUNNER_MEM job_disk <<<"${SIZE_PRESETS[$SIZE]}"
  fi
  size_defaults "$job_disk"
}

# Container totals (per container). CPU/RAM are limits, not reservations, and
# LVM-thin/ZFS disks are thin-provisioned, so unused headroom costs nothing.
size_defaults() {   # size_defaults <job disk GB per runner>
  local image_gb=3 per; [[ "$RUNNER_FLAVOR" == full ]] && image_gb=13
  per="$(runners_per_ct)"
  local cpus=$((per * RUNNER_CPUS))
  (( cpus > $(host_cpus) )) && cpus="$(host_cpus)"   # can't exceed host; runners share
  CORES="${CORES:-$cpus}"
  RAM="${RAM:-$((per * RUNNER_MEM + 1024))}"
  SWAP="${SWAP:-1024}"
  DISK="${DISK:-$((2 + image_gb + per * (1 + $1)))}"
}

ask_advanced() {
  local multi=""; [[ "$(ct_count)" -gt 1 ]] && multi=" (first one; the others get the next free IDs)"
  CTID="$(w_ask "Container ID${multi}" "$CTID" valid_ctid "Use a number >= 100 that no VM/container uses yet.")"
  multi=""; [[ "$(ct_count)" -gt 1 ]] && multi=" (-1, -2, ... is appended)"
  CT_HOSTNAME="$(w_ask "Hostname${multi}" "$CT_HOSTNAME" valid_free_hostname \
    "Letters, digits and '-', must start with a letter or digit, max 63 - and not used by another container.")"
  CORES="$(w_ask "CPU cores per container" "$CORES" valid_posint "Enter a whole number, e.g. 4.")"
  RAM="$(w_ask "RAM per container in MB" "$RAM" valid_posint "Enter a whole number of MB, e.g. 8192.")"
  SWAP="$(w_ask "Swap per container in MB" "$SWAP" valid_posint "Enter a whole number of MB, e.g. 1024.")"
  DISK="$(w_ask "Disk per container in GB" "$DISK" valid_posint "Enter a whole number of GB, e.g. 20.")"
  BRIDGE="$(w_ask "Network bridge" "$BRIDGE" valid_bridge "No such bridge on this host. Existing: $(ip -o link show type bridge | awk -F': ' '{print $2}' | tr '\n' ' ')" normalize_trim)"
  multi=""; [[ "$(ct_count)" -gt 1 ]] && multi="
With ${RUNNER_COUNT} containers, a static IP is counted up (.50, .51, ...)."
  NET_IP="$(w_ask "IPv4: 'dhcp' or address/prefix, e.g. 192.168.1.50/24${multi}" "$NET_IP" valid_net_ip "Use 'dhcp' or an address with prefix, e.g. 192.168.1.50/24." normalize_trim)"
  if [[ "$NET_IP" != dhcp ]]; then
    NET_GW="$(w_ask "IPv4 gateway (empty = none)" "$NET_GW" valid_gw "Use an IPv4 address, e.g. 192.168.1.1." normalize_trim)"
  fi
  VLAN="$(w_ask "VLAN tag (empty = none)" "$VLAN" valid_vlan "Use a number from 1 to 4094, or leave empty." normalize_trim)"
  SSH_KEYS="$(w_ask "Path to an SSH public key file for root (empty = none)" "$SSH_KEYS" valid_sshkey "File not found on this host." normalize_trim)"
  if [[ "$NET_ISOLATION" == internet ]]; then
    DNS_SERVERS="$(w_ask "Public DNS servers for the container (space-separated)" "$DNS_SERVERS" valid_dns \
      "Use public IPv4 resolvers, e.g. '1.1.1.1 9.9.9.9'. LAN resolvers are blocked by the isolation.")"
    LAN_ALLOW="$(w_ask "LAN exceptions jobs MAY reach, e.g. an internal registry
(comma-separated IPv4 addresses or CIDRs, empty = none)" "$LAN_ALLOW" valid_lan_allow \
      "Use e.g. 10.0.0.5 or 10.0.0.5,192.168.50.0/24." normalize_csv)"
  fi
  if w_yesno "Unprivileged container? (recommended)" 1; then UNPRIVILEGED=1; else UNPRIVILEGED=0; fi
}

ask_settings() {
  RUNNER_FLAVOR="$(w_menu "Runner image" "$RUNNER_FLAVOR" \
    standard "git, gh, Docker, Python, Node, build tools, kubectl, helm (~3 GB)" \
    full     "standard + Go, Java, .NET, Rust, PHP, Ruby, pwsh, browsers, clouds (~13 GB)")"
  ask_parallel
  ask_size

  NET_ISOLATION="$(w_menu "Network access for jobs" "$NET_ISOLATION" \
    internet "Internet only: LAN, Proxmox host and other guests blocked (recommended)" \
    lan      "No restrictions: jobs can reach your whole network")"

  local mode per_ct=""
  [[ "$(ct_count)" -gt 1 ]] && per_ct=" each"
  mode="$(w_menu "Container settings" default \
    default  "$(ct_count) x CT from ${CTID}: ${CORES} cores, ${RAM} MB, ${DISK} GB${per_ct}, DHCP" \
    advanced "Choose everything yourself")"
  [[ "$mode" == advanced ]] && ask_advanced

  RUNNER_PREFIX="$(w_ask "Runner name as shown in GitHub (-1, -2, ... is appended when more than one)" \
    "${RUNNER_PREFIX:-$CT_HOSTNAME}" valid_name "Letters, digits and '-', must start with a letter or digit." normalize_trim)"
  RUNNER_LABELS="$(w_ask "Extra labels for runs-on, comma-separated, e.g. docker,gpu
(self-hosted, linux, x64 are added automatically)" "$RUNNER_LABELS" valid_labels \
    "Each label may use letters, digits, '.', '_' and '-' (max 64). Separate labels with commas." normalize_labels)"
  if [[ ! "$GH_URL" =~ ^https://[^/]+/[^/]+/[^/]+$ ]] || [[ "$GH_URL" == */enterprises/* ]]; then
    RUNNER_GROUP="$(w_ask "Runner group (empty = Default)" "$RUNNER_GROUP" valid_any "" normalize_trim)"
  fi

  ROOT_STORAGE="$(pick_storage rootdir "the container disk")"
  TMPL_STORAGE="$(pick_storage vztmpl "container templates")"

  plan_containers
  validate_settings
}

# ip_offset 192.168.1.50/24 2 -> 192.168.1.52/24
ip_offset() {
  local addr="${1%/*}" mask="${1#*/}" a b c d
  IFS=. read -r a b c d <<<"$addr"
  d=$((d + $2))
  (( d < 255 )) || die "Static IP range overflows: ${addr} + $2"
  echo "${a}.${b}.${c}.${d}/${mask}"
}

# Resolve per-container ID, hostname, IP and runner prefix.
plan_containers() {
  PLAN_IDS=() PLAN_NAMES=() PLAN_IPS=() PLAN_PREFIXES=()
  local i n id="$CTID"
  n="$(ct_count)"
  for ((i = 0; i < n; i++)); do
    id="$(next_free_id "$id")"
    PLAN_IDS+=("$id")
    if (( n > 1 )); then
      PLAN_NAMES+=("${CT_HOSTNAME}-$((i + 1))")
      PLAN_PREFIXES+=("${RUNNER_PREFIX}-$((i + 1))")
    else
      PLAN_NAMES+=("$CT_HOSTNAME")
      PLAN_PREFIXES+=("$RUNNER_PREFIX")
    fi
    if [[ "$NET_IP" == dhcp ]]; then PLAN_IPS+=(dhcp); else PLAN_IPS+=("$(ip_offset "$NET_IP" "$i")"); fi
    id=$((id + 1))
  done
}

# Final gate, also covers values passed via environment in NONINTERACTIVE mode.
validate_settings() {
  valid_url "$GH_URL" || die "Invalid GitHub URL: $GH_URL"
  valid_name "$CT_HOSTNAME" || die "Invalid hostname: $CT_HOSTNAME"
  valid_name "$RUNNER_PREFIX" || die "Invalid runner name: $RUNNER_PREFIX"
  local n
  for n in CORES RAM SWAP DISK RUNNER_CPUS RUNNER_MEM; do valid_posint "${!n}" || die "$n must be a positive number"; done
  valid_count "$RUNNER_COUNT" || die "Runner count must be 1-32"
  [[ "$LAYOUT" == shared || "$LAYOUT" == separate ]] || die "LAYOUT must be shared|separate"
  [[ "$NET_ISOLATION" == internet || "$NET_ISOLATION" == lan ]] || die "NET_ISOLATION must be internet|lan"
  valid_dns "$DNS_SERVERS" || die "Invalid DNS servers: $DNS_SERVERS"
  valid_lan_allow "$LAN_ALLOW" || die "Invalid LAN exceptions: $LAN_ALLOW"
  RUNNER_LABELS="$(normalize_labels "$RUNNER_LABELS")"
  valid_labels "$RUNNER_LABELS" || die "Invalid labels: $RUNNER_LABELS"
  valid_net_ip "$NET_IP" || die "Invalid IPv4: $NET_IP"
  valid_gw "$NET_GW" || die "Invalid gateway: $NET_GW"
  valid_vlan "$VLAN" || die "Invalid VLAN tag: $VLAN"
  valid_sshkey "$SSH_KEYS" || die "SSH key file not found: $SSH_KEYS"
  valid_bridge "$BRIDGE" || die "Bridge $BRIDGE does not exist"

  local taken name
  taken=" $(all_ct_hostnames | tr '\n' ' ') "
  for name in "${PLAN_NAMES[@]}"; do
    [[ "$taken" == *" ${name} "* ]] && die "Hostname '${name}' is already used by another container on this host."
  done

  local total_ram=$(( RAM * $(ct_count) ))
  if (( total_ram > $(host_ram_mb) )); then
    w_yesno "The RAM limits add up to ${total_ram} MB, more than the host's $(host_ram_mb) MB.
That works (they are only limits), but parallel heavy jobs could make the
host swap.

Continue anyway?" 0 || die "Choose a smaller size or fewer runners."
  fi
}

confirm() {
  local mode=persistent; [[ "$RUNNER_EPHEMERAL" == 1 ]] && mode=ephemeral
  local i list="" n; n="$(ct_count)"
  for ((i = 0; i < n; i++)); do
    list+="    CT ${PLAN_IDS[$i]}  ${PLAN_NAMES[$i]}  ${PLAN_IPS[$i]}  -> runner(s) ${PLAN_PREFIXES[$i]}$( [[ "$(runners_per_ct)" -gt 1 ]] && echo "-1..$(runners_per_ct)")
"
  done
  local whiptail_height=$(( 22 + n ))
  [[ "$NONINTERACTIVE" == 1 ]] && return 0
  whiptail --backtitle "$TITLE" --title "$APP" --yesno "Ready to create:

  Parallel    ${RUNNER_COUNT} job(s) at once - ${RUNNER_COUNT} runner(s) in ${n} container(s) (${LAYOUT})
${list}
  Each CT     ${CORES} cores, ${RAM} MB RAM, ${DISK} GB on ${ROOT_STORAGE}, $([[ $UNPRIVILEGED == 1 ]] && echo unprivileged || echo privileged)
  Per runner  ${RUNNER_CPUS} CPU, ${RUNNER_MEM} MB RAM (${SIZE})
  Network     ${BRIDGE}${VLAN:+ vlan ${VLAN}}, $([[ $NET_ISOLATION == internet ]] && echo "internet only${LAN_ALLOW:+ (+${LAN_ALLOW})}" || echo "full LAN access")
  GitHub      ${GH_URL}
  Mode        ${mode}, image ${RUNNER_FLAVOR}
  Labels      self-hosted,linux,x64${RUNNER_LABELS:+,${RUNNER_LABELS}}

Continue?" "$whiptail_height" 90 || exit_cancel
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

create_ct() {   # uses CTID, CUR_HOSTNAME, CUR_IP
  local net="name=eth0,bridge=${BRIDGE},ip=${CUR_IP}"
  [[ -n "$NET_GW" ]] && net+=",gw=${NET_GW}"
  [[ -n "$VLAN" ]] && net+=",tag=${VLAN}"
  [[ "$NET_ISOLATION" == internet ]] && net+=",firewall=1"

  local args=(
    --hostname "$CUR_HOSTNAME"
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
  # Fixed public resolvers: a DHCP-provided LAN resolver would be blocked anyway.
  [[ "$NET_ISOLATION" == internet ]] && args+=(--nameserver "$DNS_SERVERS")

  msg_info "Creating LXC ${CTID} (${CUR_HOSTNAME})"
  CREATED_CTS+=("$CTID")   # first: a half-finished create still gets cleaned up
  pct create "$CTID" "$TEMPLATE" "${args[@]}" >/dev/null
  msg_ok "Created LXC ${CTID} (${CUR_HOSTNAME})"
}

# ------------------------------------------------------------------ firewall --
# Enforced by the Proxmox host on the CT's NIC. Rules inside the CT would be
# useless: jobs control Docker there and therefore have root.
# IPv6 is blocked entirely: LAN devices often have *global* IPv6 addresses
# that no private range covers. Internet access works over IPv4.
PRIVATE_NETS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16
              224.0.0.0/4 ::/1 8000::/1)   # ipset rejects /0: two halves = all IPv6

is_private_ip() {
  [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.|127\.) \
     || "$1" =~ ^(fc|fd|fe80) ]]
}

# The datacenter-level switch must be on for any guest firewall to apply.
ensure_cluster_firewall() {
  local fw=/etc/pve/firewall/cluster.fw
  if [[ -f "$fw" ]] && grep -qE '^enable:[[:space:]]*1' "$fw"; then
    return 0
  fi
  if [[ -f "$fw" ]] && grep -qE '^policy_in:[[:space:]]*DROP' "$fw"; then
    w_yesno "The datacenter firewall is OFF and its input policy is DROP.

Turning it on would apply that DROP policy to the Proxmox host and could
lock you out of the web UI/SSH. Enable it anyway?" 0 \
      || die "Isolation needs the datacenter firewall. Enable it yourself, or re-run with NET_ISOLATION=lan."
    pvesh set /cluster/firewall/options --enable 1 >/dev/null
  else
    w_yesno "Network isolation needs the Proxmox datacenter firewall, which is OFF.

It will be enabled with input policy ACCEPT, so the host and all other
guests keep working exactly as before. Only this container gets rules.

Enable it?" 1 || die "Isolation needs the datacenter firewall (or re-run with NET_ISOLATION=lan)."
    pvesh set /cluster/firewall/options --enable 1 --policy_in ACCEPT >/dev/null
  fi
  msg_ok "Datacenter firewall enabled"
}

write_ct_firewall() {
  local fw="/etc/pve/firewall/${CTID}.fw" net item
  {
    echo "[OPTIONS]"
    echo "enable: 1"
    echo "policy_in: DROP"      # nothing may connect in (pct enter still works)
    echo "policy_out: ACCEPT"   # internet allowed, LAN dropped by rules below
    echo "dhcp: 1"
    echo "ndp: 1"
    echo "macfilter: 1"
    echo
    echo "[IPSET lan_block] # private, CGNAT, link-local, multicast"
    for net in "${PRIVATE_NETS[@]}"; do echo "$net"; done
    # The Proxmox host itself, even when it has public addresses.
    for net in $(hostname -I); do echo "$net"; done
    if [[ -n "$LAN_ALLOW" ]]; then
      echo
      echo "[IPSET lan_allow] # explicitly allowed LAN targets"
      IFS=',' read -ra items <<<"$LAN_ALLOW"
      for item in "${items[@]}"; do [[ -n "$item" ]] && echo "$item"; done
    fi
    echo
    echo "[RULES]"
    [[ -n "$LAN_ALLOW" ]] && echo "OUT ACCEPT -dest +lan_allow -log nolog"
    # REJECT (not DROP): blocked connections fail instantly, no timeouts.
    echo "OUT REJECT -dest +lan_block -log nolog"
  } >"$fw"
  msg_ok "Firewall: internet only${LAN_ALLOW:+, plus ${LAN_ALLOW}}"
}

setup_firewall() {
  [[ "$NET_ISOLATION" == internet ]] || return 0
  ensure_cluster_firewall
  write_ct_firewall
}

# Prove it: GitHub must work, the Proxmox host (web UI port) must not.
verify_isolation() {
  [[ "$NET_ISOLATION" == internet ]] || return 0
  local host_ip probe='timeout 4 bash -c "</dev/tcp/$1/$2" 2>/dev/null'
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)"
  local gw; gw="$(pct exec "$CTID" -- ip -4 route show default | awk '{print $3; exit}')"
  msg_info "Verifying network isolation"
  sleep 12   # pve-firewall applies config changes within ~10s
  pct exec "$CTID" -- bash -c "$probe" _ github.com 443 \
    || die "Container cannot reach github.com:443 through the firewall."
  if [[ -n "$host_ip" ]] && pct exec "$CTID" -- bash -c "$probe" _ "$host_ip" 8006; then
    die "Isolation NOT effective: container reaches the Proxmox host ${host_ip}:8006. Check 'pve-firewall status'."
  fi
  if [[ -n "$gw" ]] && pct exec "$CTID" -- bash -c "$probe" _ "$gw" 80; then
    die "Isolation NOT effective: container reaches its gateway ${gw}:80 (router UI)."
  fi
  msg_ok "Isolated: github.com reachable; Proxmox host ${host_ip:-?} and gateway ${gw:-?} blocked"
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

# Phase 1 (per container): register runners right away - the pair code
# expires after 1 hour, and building images for several containers takes longer.
register_runners() {   # uses CTID, CUR_PREFIX
  local tmp; tmp="$(mktemp)"
  BOOTSTRAP_TMP="$tmp"   # removed by on_exit even if pct push fails
  chmod 600 "$tmp"
  {
    printf 'GH_URL=%q\n' "$GH_URL"
    printf 'GH_TOKEN=%q\n' "${GH_TOKEN:-}"
    printf 'GH_PAT=%q\n' "${GH_PAT:-}"
    printf 'RUNNER_EPHEMERAL=%q\n' "$RUNNER_EPHEMERAL"
    printf 'RUNNER_PREFIX=%q\n' "$CUR_PREFIX"
    printf 'RUNNER_COUNT=%q\n' "$(runners_per_ct)"
    printf 'RUNNER_LABELS=%q\n' "$RUNNER_LABELS"
    printf 'RUNNER_GROUP=%q\n' "$RUNNER_GROUP"
    printf 'RUNNER_FLAVOR=%q\n' "$RUNNER_FLAVOR"
    printf 'RUNNER_CPUS=%q\n' "$RUNNER_CPUS"
    printf 'RUNNER_MEM=%q\n' "$RUNNER_MEM"
  } >"$tmp"
  pct push "$CTID" "$tmp" /root/.gha-bootstrap.env --perms 600
  rm -f "$tmp"; BOOTSTRAP_TMP=""

  msg_info "Registering runner(s) ${CUR_PREFIX} with GitHub"
  pct exec "$CTID" -- bash "${CT_REPO_DIR}/lxc/setup.sh" register /root/.gha-bootstrap.env
  msg_ok "Registered in CT ${CTID}"
}

provision_ct() {   # provision_ct <index>
  CTID="${PLAN_IDS[$1]}" CUR_HOSTNAME="${PLAN_NAMES[$1]}" CUR_IP="${PLAN_IPS[$1]}" CUR_PREFIX="${PLAN_PREFIXES[$1]}"
  printf '\n%s── Container %s/%s: CT %s (%s) ──%s\n' "$BL" "$(( $1 + 1 ))" "$(ct_count)" "$CTID" "$CUR_HOSTNAME" "$CL"
  create_ct
  setup_firewall
  start_ct
  verify_isolation
  deploy_repo
  install_docker
  register_runners
}

# Phase 2: build the image once, copy it to the other containers, start all.
finish_all() {
  local image="quavon/gha-runner:${RUNNER_FLAVOR}" first="${PLAN_IDS[0]}" id
  printf '\n%s── Runner image ──%s\n' "$BL" "$CL"
  msg_info "Building '${RUNNER_FLAVOR}' image in CT ${first} (standard ~5-10 min, full ~20-40 min)"
  pct exec "$first" -- gha-runners build --flavor "$RUNNER_FLAVOR"
  msg_ok "Image built"
  for id in "${PLAN_IDS[@]:1}"; do
    msg_info "Copying image to CT ${id}"
    if ! pct exec "$first" -- docker save "$image" | pct exec "$id" -- docker load >/dev/null; then
      msg_info "Copy failed, building in CT ${id} instead"
      pct exec "$id" -- gha-runners build --flavor "$RUNNER_FLAVOR"
    fi
  done
  for id in "${PLAN_IDS[@]}"; do
    pct exec "$id" -- bash "${CT_REPO_DIR}/lxc/setup.sh" start
  done
  msg_ok "All runners started"
}

summary() {
  local i id ip rows=""
  for i in "${!PLAN_IDS[@]}"; do
    id="${PLAN_IDS[$i]}"
    ip="$(pct exec "$id" -- hostname -I | awk '{print $1}')"
    rows+="    CT ${id}  ${PLAN_NAMES[$i]}  ${ip}
"
  done
  local shared_note=""
  [[ "$LAYOUT" == shared && "$RUNNER_COUNT" -gt 1 ]] \
    && shared_note="Runners in the same LXC can affect each other - use LAYOUT=separate for untrusted code."
  cat <<SUMMARY

${GN}${APP} are online: ${RUNNER_COUNT} runner(s) = ${RUNNER_COUNT} job(s) in parallel.${CL}

  Containers (${LAYOUT}):
${rows}
  GitHub    : ${GH_URL}  (Settings > Actions > Runners)
  Use in workflows:
      runs-on: [self-hosted, linux${RUNNER_LABELS:+, ${RUNNER_LABELS//,/, }}]

  Manage (pct enter <CT>):
      gha-runners list | add | remove <name> | logs <name> -f | limits | update

${YW}Security:${CL} jobs can use the Docker socket, i.e. they have root inside
their LXC. $([[ $NET_ISOLATION == internet ]] && echo "The host firewall keeps them off your LAN." || echo "They can reach your whole LAN.")
${shared_note}
Do not attach these runners to public repositories that accept
pull requests from forks.
SUMMARY
}

main() {
  # Running inside an existing installation = update it (helper-script convention).
  if ! command -v pveversion >/dev/null && command -v gha-runners >/dev/null; then
    exec gha-runners update
  fi
  header
  preflight
  defaults
  w_yesno "This creates LXC container(s) with Docker and GitHub Actions runners.\n\nProceed?" 1 || exit_cancel
  check_existing
  ask_github
  ask_settings
  confirm
  header
  ensure_template
  local i
  for i in "${!PLAN_IDS[@]}"; do provision_ct "$i"; done
  finish_all
  summary
}

main "$@"
