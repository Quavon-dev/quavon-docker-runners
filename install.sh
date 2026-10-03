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
TITLE="Quavon ${APP}   |   Esc = cancel"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# DEBUG=1 writes a full trace to /tmp/gha-install.log (dialogs stay usable).
if [[ "${DEBUG:-0}" == 1 ]]; then
  exec {GHA_TRACE_FD}>>/tmp/gha-install.log
  BASH_XTRACEFD=$GHA_TRACE_FD
  set -x
fi

# ---------------------------------------------------------------- ui helpers --
YW=$'\e[33m' GN=$'\e[1;92m' RD=$'\e[01;31m' BL=$'\e[36m' DIM=$'\e[2m' CL=$'\e[m'
# Progress output in the style of the Proxmox VE helper scripts:
#   ⠹ Installing Docker - Verifying Docker can run containers (0:42)
#   ✔ Installed Docker (1:07)
# Command output goes to LOG_FILE; VERBOSE=1 streams it to the terminal instead.
LOG_FILE="${LOG_FILE:-/tmp/gha-runners-install-$(date +%Y%m%d-%H%M%S).log}"
VERBOSE="${VERBOSE:-0}"
SPINNER_PID="" STEP_TEXT="" STEP_START=0 STEP_LOG_LINE=0
FANCY=0; [[ -t 1 && "$VERBOSE" != 1 ]] && FANCY=1
# The real terminal, saved before any step redirects output into the log.
# Exit/interrupt handlers switch back to it, otherwise their messages - and
# the cleanup dialog - would land in the log file and the script would sit
# waiting on an invisible prompt.
exec {TTY_OUT}>&1 {TTY_ERR}>&2
to_terminal() { exec 1>&"$TTY_OUT" 2>&"$TTY_ERR"; }

fmt_elapsed() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

spinner_stop() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r\e[K'
  fi
}

# msg_info <text> [log-pattern]: start a step. With a pattern, the newest log
# line matching it is shown as live sub-status (e.g. current build step).
msg_info() {
  spinner_stop
  STEP_TEXT="$1" STEP_START=$SECONDS
  if [[ "$FANCY" != 1 ]]; then printf ' %s…%s %s\n' "$YW" "$CL" "$1"; return 0; fi
  local text="$1" pattern="${2:-}" start=$SECONDS cols
  cols="$(tput cols 2>/dev/null || echo 80)"
  (
    # Cosmetic loop: never let errexit/ERR trap fire in here (grep "no match" is normal).
    set +eE +o pipefail; trap - ERR EXIT; trap 'exit 0' TERM
    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
    while :; do
      sub=""
      if [[ -n "$pattern" && -f "$LOG_FILE" ]]; then
        sub="$(tail -n 300 "$LOG_FILE" 2>/dev/null | grep -E "$pattern" | tail -n1 \
          | sed -E "s/$pattern//; s/\x1b\[[0-9;]*m//g; s/^[[:space:]]+//")"
      fi
      line=" ${frames[i++ % 10]} ${text}${sub:+ - ${sub}}"
      el="($(fmt_elapsed $((SECONDS - start))))"
      (( ${#line} + ${#el} + 2 > cols )) && line="${line:0:$((cols - ${#el} - 5))}..."
      printf '\r\e[K%s%s%s %s%s%s' "$YW" "$line" "$CL" "$DIM" "$el" "$CL"
      sleep 0.2
    done
  ) &
  SPINNER_PID=$!
}

msg_ok() {
  spinner_stop
  local el=""; [[ -n "$STEP_TEXT" ]] && el=" ${DIM}($(fmt_elapsed $((SECONDS - STEP_START))))${CL}"
  printf ' %s✔%s %s%s\n' "$GN" "$CL" "$*" "$el"
  STEP_TEXT=""
}
msg_warn()  { spinner_stop; printf ' %s⚠%s %s\n' "$YW" "$CL" "$*"; }
msg_error() { spinner_stop; printf ' %s✖ %s%s\n' "$RD" "$*" "$CL" >&2; STEP_TEXT=""; }
die()       { msg_error "$*"; exit 1; }

# After a failure, show the failing step's own output so the cause is visible.
show_log_tail() {
  [[ "$VERBOSE" == 1 || ! -s "$LOG_FILE" ]] && return 0
  printf '\n%s--- output of the failed step (full log: %s) ---%s\n' "$DIM" "$LOG_FILE" "$CL" >&2
  tail -n +"$((STEP_LOG_LINE + 1))" "$LOG_FILE" | tail -n 25 | sed 's/^/   /' >&2
  printf '%s---%s\n\n' "$DIM" "$CL" >&2
}

# run <cmd...>: run a step command with output in the log (or live in VERBOSE).
run() {
  printf '\n### %s\n' "$*" >>"$LOG_FILE"
  STEP_LOG_LINE="$(wc -l <"$LOG_FILE")"
  if [[ "$VERBOSE" == 1 ]]; then
    "$@" </dev/null 2>&1 | tee -a "$LOG_FILE"
  else
    "$@" </dev/null >>"$LOG_FILE" 2>&1
  fi
}

# step <text> <done-text> [--status PATTERN] -- <cmd...>
# Spinner while the command runs; ✔ on success, ✖ + log tail + exit on failure.
step() {
  local text="$1" done="$2" pattern=""; shift 2
  if [[ "${1:-}" == --status ]]; then pattern="$2"; shift 2; fi
  [[ "${1:-}" == -- ]] && shift
  msg_info "$text" "$pattern"
  local rc=0
  run "$@" || rc=$?
  if [[ "$rc" == 0 ]]; then msg_ok "$done"; return 0; fi
  msg_error "${text} failed (exit ${rc})"
  show_log_tail
  exit "$rc"
}

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
  # whiptail would parse a pre-filled value starting with '-' as an option
  local init="$2"; [[ "$init" == -* ]] && init=""
  whiptail --backtitle "$TITLE" --title "$APP" --inputbox "$1" 12 78 "$init" 3>&1 1>&2 2>&3 || exit_cancel
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
w_yesno() {   # w_yesno <text> [default-yes:1|0]  (0 = Enter means "No")
  [[ "$NONINTERACTIVE" == 1 ]] && { [[ "${2:-1}" == 1 ]]; return; }
  local def=(); [[ "${2:-1}" == 0 ]] && def=(--defaultno)
  # >&2: draw on the terminal even when called inside $(...) (stdout captured)
  whiptail --backtitle "$TITLE" --title "$APP" "${def[@]}" --yesno "$1" 14 78 >&2
}
w_msg() {     # w_msg <text> [height]
  [[ "$NONINTERACTIVE" == 1 ]] && return 0
  whiptail --backtitle "$TITLE" --title "$APP" --msgbox "$1" "${2:-14}" 78 >&2
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
REGISTERED_RUNNERS=()
BOOTSTRAP_TMP=""
on_error() {
  local rc=$?
  [[ "$rc" == 130 ]] && return 0
  # Only the main shell reports. A failure inside $(...) either reaches the
  # main shell (and is reported there once) or is handled on purpose, e.g. in
  # an `if` condition - printing "failed" for it would be a false alarm.
  (( BASH_SUBSHELL == 0 )) || return 0
  to_terminal
  msg_error "${STEP_TEXT:-Installer} failed (exit ${rc}, line $1)"
  show_log_tail
}
# Runs on every exit (die, ERR, signals): wipe secrets, offer to drop a broken CT.
on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  to_terminal
  spinner_stop
  [[ "$FANCY" == 1 ]] && tput cnorm 2>/dev/null
  [[ "$rc" != 0 && "$rc" != 130 && -s "$LOG_FILE" ]] && msg_warn "Full log: ${LOG_FILE}"
  [[ -n "$BOOTSTRAP_TMP" ]] && rm -f "$BOOTSTRAP_TMP"
  if [[ "$rc" != 0 && ${#CREATED_CTS[@]} -gt 0 ]]; then
    if w_yesno "Installation failed.\n\nDestroy the container(s) created by this run: ${CREATED_CTS[*]}?" 0; then
      local id
      for id in "${CREATED_CTS[@]}"; do
        pct stop "$id" >/dev/null 2>&1 || true
        pct destroy "$id" --purge >/dev/null 2>&1 && msg_ok "Destroyed container ${id}"
      done
      if ((${#REGISTERED_RUNNERS[@]})); then
        msg_warn "Already registered in GitHub (now offline): ${REGISTERED_RUNNERS[*]}"
        msg_warn "Remove them under ${GH_URL}/settings/actions/runners - a re-run with the same name would clash"
      fi
    else
      msg_warn "Kept for debugging: ${CREATED_CTS[*]} (pct enter <id>)"
    fi
  fi
  exit "$rc"
}
trap 'on_error $LINENO' ERR
trap on_exit EXIT
# Ctrl+C / kill always ends the installer (on_exit still cleans up). Without
# this, bash may carry on with the next command after the child was killed.
trap 'to_terminal; printf "\n"; msg_error "Interrupted"; exit 130' INT TERM HUP

# ----------------------------------------------------------------- preflight --
# Host commands get a timeout: a hung pmxcfs/pvesh must produce an error,
# never a silent freeze.
pve() {   # pve <seconds> <cmd...>
  local secs="$1"; shift
  # Plain timeout (not --foreground): kills the whole process group, so a hung
  # child process can't keep $(...) waiting forever.
  timeout -k 5 "${PVE_TIMEOUT:-$secs}" "$@" </dev/null || {
    local rc=$?
    [[ "$rc" == 124 ]] && die "'$*' did not answer within ${PVE_TIMEOUT:-$secs}s - is the Proxmox cluster filesystem (pve-cluster) healthy? Try: systemctl status pve-cluster"
    return "$rc"
  }
}

preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox VE host."
  command -v pveversion >/dev/null || die "This script must run on a Proxmox VE host."
  local c
  for c in pct pveam pvesm pvesh whiptail timeout; do command -v "$c" >/dev/null || die "missing command: $c"; done
  [[ "$(dpkg --print-architecture)" == amd64 ]] || die "Only amd64 Proxmox hosts are supported."
  local ver; ver="$(pve 20 pveversion | grep -oP 'pve-manager/\K[0-9.]+' || true)"
  [[ "${ver%%.*}" =~ ^[0-9]+$ && "${ver%%.*}" -ge 8 ]] || die "Proxmox VE 8 or newer required (found: '${ver:-unknown}')."
  if [[ "$NONINTERACTIVE" != 1 ]]; then
    [[ -t 0 && -t 1 ]] || die "Needs an interactive terminal. Run it in a shell, or use NONINTERACTIVE=1 (see README)."
    local rows cols
    read -r rows cols < <(stty size 2>/dev/null || echo "24 80")
    (( rows >= 24 && cols >= 80 )) || die "Terminal is ${cols}x${rows}; the dialogs need at least 80x24. Enlarge the window and retry."
  fi
  msg_ok "Proxmox VE ${ver} host, running as root"
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
  id_free "$1"
}
valid_any() { return 0; }


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
  done < <(timeout 30 pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active"')
  [[ ${#items[@]} -gt 0 ]] || die "No active storage supports '${content}'."
  if [[ ${#items[@]} -eq 2 ]]; then echo "$first"; return; fi
  w_menu "Storage for ${label}" "$first" "${items[@]}"
}

# IDs come from Proxmox itself, exactly like the helper scripts: no scanning of
# other guests. `pvesh get /cluster/nextid --vmid N` fails if N is taken.
id_free() { pve 20 pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1; }
next_id() { pve 20 pvesh get /cluster/nextid; }

defaults() {
  CTID="${CTID:-$(next_id)}"
  CT_HOSTNAME="${CT_HOSTNAME:-gha-runners}"
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
  CTID="$(w_ask "Container ID${multi}" "$CTID" valid_ctid "Use a number >= 100 that no VM/container uses yet (next free: $(next_id)).")"
  multi=""; [[ "$(ct_count)" -gt 1 ]] && multi=" (-1, -2, ... is appended)"
  CT_HOSTNAME="$(w_ask "Hostname${multi}" "$CT_HOSTNAME" valid_name \
    "Letters, digits and '-', must start with a letter or digit, max 63.")"
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
  local i n
  n="$(ct_count)"
  for ((i = 0; i < n; i++)); do
    PLAN_IDS+=("$([[ $i == 0 ]] && echo "$CTID" || echo next)")   # "next" = resolved at creation
    if (( n > 1 )); then
      PLAN_NAMES+=("${CT_HOSTNAME}-$((i + 1))")
      PLAN_PREFIXES+=("${RUNNER_PREFIX}-$((i + 1))")
    else
      PLAN_NAMES+=("$CT_HOSTNAME")
      PLAN_PREFIXES+=("$RUNNER_PREFIX")
    fi
    if [[ "$NET_IP" == dhcp ]]; then PLAN_IPS+=(dhcp); else PLAN_IPS+=("$(ip_offset "$NET_IP" "$i")"); fi
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
  local id_txt range=""
  (( $(runners_per_ct) > 1 )) && range="-1..$(runners_per_ct)"
  for ((i = 0; i < n; i++)); do
    id_txt="${PLAN_IDS[$i]}"; [[ "$id_txt" == next ]] && id_txt="(next free)"
    list+="    CT ${id_txt}  ${PLAN_NAMES[$i]}  ${PLAN_IPS[$i]}  -> runner(s) ${PLAN_PREFIXES[$i]}${range}
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

Continue?" "$whiptail_height" 78 >&2 || exit_cancel
}

# ----------------------------------------------------------------- container --
# Every command inside a container goes through ct(): `pct exec` passes the
# host's environment along (e.g. LC_ALL=en_US.UTF-8, which the container has
# no locale for -> perl/apt warnings) and does not reliably include
# /usr/local/bin in PATH (-> "gha-runners: command not found").
CT_ENV=(env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE= DEBIAN_FRONTEND=noninteractive)
ct() {   # ct <ctid> <cmd...>
  local id="$1"; shift
  pct exec "$id" -- "${CT_ENV[@]}" "$@"
}

# Newest Debian 13 (else 12) standard template FOR THIS HOST'S ARCHITECTURE.
# Template indexes can list several architectures (e.g. ..._arm64.tar.zst next
# to ..._amd64.tar.zst); a foreign one fails with "Failed to spawn container".
find_template() {
  local available tmpl="" v arch
  arch="$(dpkg --print-architecture)"
  available="$(pveam available --section system | awk '{print $2}')"
  for v in 13 12; do
    tmpl="$(awk -v p="^debian-${v}-standard_.*_${arch}[.]tar[.]" '$0 ~ p' <<<"$available" | sort -V | tail -n1)"
    [[ -n "$tmpl" ]] && break
  done
  echo "$tmpl"
}

ensure_template() {
  step "Updating LXC template list" "Updated LXC template list" -- bash -c 'pveam update || true'
  local tmpl; tmpl="$(find_template)"
  [[ -n "$tmpl" ]] || die "No Debian 12/13 $(dpkg --print-architecture) template available from pveam (check: pveam available --section system)."
  if grep -qF "$tmpl" <<<"$(pveam list "$TMPL_STORAGE")"; then
    msg_ok "Template ${tmpl} already present"
  else
    step "Downloading template ${tmpl}" "Downloaded template ${tmpl}" -- pveam download "$TMPL_STORAGE" "$tmpl"
  fi
  TEMPLATE="${TMPL_STORAGE}:vztmpl/${tmpl}"
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

  CREATED_CTS+=("$CTID")   # first: a half-finished create still gets cleaned up
  step "Creating LXC container ${CTID}" \
    "Created LXC ${CTID} (${CUR_HOSTNAME}: ${CORES} cores, ${RAM} MB, ${DISK} GB)" \
    -- pct create "$CTID" "$TEMPLATE" "${args[@]}"
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
    msg_ok "Datacenter firewall is enabled"
    return 0
  fi
  if [[ -f "$fw" ]] && grep -qE '^policy_in:[[:space:]]*DROP' "$fw"; then
    w_yesno "The datacenter firewall is OFF and its input policy is DROP.

Turning it on would apply that DROP policy to the Proxmox host and could
lock you out of the web UI/SSH. Enable it anyway?" 0 \
      || die "Isolation needs the datacenter firewall. Enable it yourself, or re-run with NET_ISOLATION=lan."
    step "Enabling datacenter firewall" "Enabled datacenter firewall" -- pvesh set /cluster/firewall/options --enable 1
  else
    w_yesno "Network isolation needs the Proxmox datacenter firewall, which is OFF.

It will be enabled with input policy ACCEPT, so the host and all other
guests keep working exactly as before. Only this container gets rules.

Enable it?" 1 || die "Isolation needs the datacenter firewall (or re-run with NET_ISOLATION=lan)."
    step "Enabling datacenter firewall" "Enabled datacenter firewall (input policy ACCEPT)" \
      -- pvesh set /cluster/firewall/options --enable 1 --policy_in ACCEPT
  fi
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
}

setup_firewall() {
  [[ "$NET_ISOLATION" == internet ]] || return 0
  ensure_cluster_firewall
  step "Writing firewall rules" "Firewall rules: internet only${LAN_ALLOW:+, plus ${LAN_ALLOW}}" -- write_ct_firewall
}

# Prove it: GitHub must work, the Proxmox host (web UI port) and gateway must not.
probe() { ct "$CTID" bash -c 'timeout 4 bash -c "</dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null; }

# pve-firewall only generates rules for running guests, on its ~10 s cycle.
# Probing before the rules for this CT's NIC exist gives false "REACHABLE".
wait_firewall_rules() {
  local _
  for _ in $(seq 1 20); do
    if iptables-save 2>/dev/null | grep -q -- "veth${CTID}i0-OUT" \
       || nft list ruleset 2>/dev/null | grep -q -- "veth${CTID}i0"; then
      echo "firewall rules for veth${CTID}i0 are active"
      sleep 2   # let the rest of the ruleset (ipsets) settle
      return 0
    fi
    sleep 2
  done
  echo "rules for veth${CTID}i0 not visible after 40 s - probing anyway"
}

# probe_blocked <host> <port>: true once the target is unreachable; retries so
# a ruleset that is still loading doesn't count as a leak.
probe_blocked() {
  local _
  for _ in 1 2 3 4 5 6; do
    probe "$1" "$2" || return 0
    sleep 5
  done
  return 1
}

check_isolation() {
  local host_ip gw _
  wait_firewall_rules
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)"
  gw="$(ct "$CTID" ip -4 route show default | awk '{print $3; exit}')"
  # pve-firewall applies rule changes every ~10 s: give it a few tries.
  dns_still_ok || { echo "DNS lookups fail in the container (resolver: $(ct "$CTID" awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd' '))"; return 1; }
  for _ in 1 2 3 4 5 6; do
    probe github.com 443 && break
    sleep 5
  done
  probe github.com 443 || { echo "github.com:443 NOT reachable"; return 1; }
  echo "github.com:443 reachable"
  if [[ -n "$host_ip" ]] && ! probe_blocked "$host_ip" 8006; then echo "Proxmox host ${host_ip}:8006 REACHABLE"; return 2; fi
  echo "Proxmox host ${host_ip:-?}:8006 blocked"
  if [[ -n "$gw" ]] && ! probe_blocked "$gw" 80; then echo "gateway ${gw}:80 REACHABLE"; return 2; fi
  echo "gateway ${gw:-?}:80 blocked"
  ISO_SUMMARY="github.com reachable; host ${host_ip:-?} and gateway ${gw:-?} blocked"
}

# Everything needed to understand a failed isolation check, into the log,
# plus a short on-screen summary. Runs tolerant: a missing tool or an empty
# grep must never abort the installer.
isolation_diagnostics() {
  ( set +e +o pipefail; trap - ERR; collect_isolation_diagnostics ) || true
}

collect_isolation_diagnostics() {
  {
    echo "=== isolation diagnostics for CT ${CTID}"
    echo "--- host: pve-firewall status";   pve-firewall status 2>&1
    echo "--- host: pve-firewall compile (errors/warnings)"
    timeout 30 pve-firewall compile 2>&1 | grep -vE '^[[:space:]]*-[AIN] ' | grep -iE "unable to|error|warn" | head -20
    echo "--- host: /etc/pve/firewall/cluster.fw"; cat /etc/pve/firewall/cluster.fw 2>&1
    echo "--- host: /etc/pve/firewall/${CTID}.fw"; cat "/etc/pve/firewall/${CTID}.fw" 2>&1
    echo "--- host: net0";                   grep -E '^net0' "/etc/pve/lxc/${CTID}.conf" 2>&1
    echo "--- host: iptables rules for this CT"
    iptables-save 2>/dev/null | grep -E "veth${CTID}i0|PVEFW-${CTID}|lan_block|lan_allow" | head -40
    echo "--- host: nftables rules for this CT"
    nft list ruleset 2>/dev/null | grep -iE "veth${CTID}i0|${CTID}|lan_block" | head -40
    echo "--- ct: addresses / routes / resolver"
    ct "$CTID" ip -br addr 2>&1
    ct "$CTID" ip route 2>&1
    ct "$CTID" cat /etc/resolv.conf 2>&1
    echo "--- ct: getent ahosts github.com"; ct "$CTID" getent ahosts github.com 2>&1 | head -4
  } >>"$LOG_FILE" 2>&1

  local gh_ip by_ip dns_ok=no
  gh_ip="$(ct "$CTID" getent ahostsv4 github.com 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ -n "$gh_ip" ]] && dns_ok=yes
  by_ip="$( { [[ -n "$gh_ip" ]] && probe "$gh_ip" 443 && echo yes; } || echo no)"
  local cf; cf="$(probe 1.1.1.1 443 && echo yes || echo no)"
  {
    echo "--- ct: DNS works: ${dns_ok} (github.com -> ${gh_ip:-?})"
    echo "--- ct: TCP ${gh_ip:-github}:443 by IP: ${by_ip}; TCP 1.1.1.1:443: ${cf}"
  } >>"$LOG_FILE"
  msg_warn "Diagnostics: DNS ${dns_ok}, TCP github:443 ${by_ip}, TCP 1.1.1.1:443 ${cf} - firewall: $(pve-firewall status 2>&1 | head -1)"
  local errs; errs="$(timeout 30 pve-firewall compile 2>&1 | grep -vE '^[[:space:]]*-[AIN] ' | grep -iE "unable to|error|warning" | head -3 || true)"
  [[ -n "$errs" ]] && msg_warn "pve-firewall reports: ${errs//$'\n'/ | }"
}

# Turn the isolation off for THIS container only (user's explicit choice);
# further containers in a separate layout are still isolated and checked.
NO_ISOLATION_CTS=()
disable_isolation() {
  rm -f "/etc/pve/firewall/${CTID}.fw"
  NO_ISOLATION_CTS+=("$CTID")
}

verify_isolation() {
  [[ "$NET_ISOLATION" == internet ]] || return 0
  local rc choice
  while true; do
    ISO_SUMMARY="" rc=0
    msg_info "Verifying network isolation"
    run check_isolation || rc=$?
    if [[ "$rc" == 0 ]]; then msg_ok "Isolation verified: ${ISO_SUMMARY}"; return 0; fi
    msg_error "Isolation check failed: $(tail -n1 "$LOG_FILE")"
    isolation_diagnostics
    [[ "$NONINTERACTIVE" == 1 ]] && die "Network isolation could not be verified (details in ${LOG_FILE}). Re-run with NET_ISOLATION=lan to skip it."
    local what="The container cannot reach github.com:443 with the firewall rules active."
    [[ "$rc" == 2 ]] && what="The firewall does NOT block the LAN: $(tail -n1 "$LOG_FILE")."
    choice="$(w_menu "${what}

Details (and the rules) are in ${LOG_FILE}.
Nothing has been installed in the container yet." retry \
      retry    "Check again" \
      lan      "Continue WITHOUT isolation (jobs can reach your LAN)" \
      abort    "Stop the installation")"
    case "$choice" in
      retry) continue ;;
      lan)
        disable_isolation
        msg_warn "Continuing without network isolation for CT ${CTID}"
        return 0 ;;
      *) die "Stopped. Firewall details: ${LOG_FILE}" ;;
    esac
  done
}

wait_network() {
  local _
  for _ in $(seq 1 60); do
    ct "$CTID" getent hosts github.com >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Re-check DNS right before the isolation probes; re-pin once if a DHCP
# client changed the resolver in the meantime.
dns_still_ok() {
  ct "$CTID" getent hosts github.com >/dev/null 2>&1 && return 0
  [[ "$NET_ISOLATION" == internet ]] && pin_dns >/dev/null 2>&1
  sleep 3
  ct "$CTID" getent hosts github.com >/dev/null 2>&1
}

start_ct() {
  step "Starting container ${CTID}" "Started container ${CTID}" -- pct start "$CTID"
  [[ "$NET_ISOLATION" == internet ]] && step "Pinning public DNS (${DNS_SERVERS})" "DNS pinned to ${DNS_SERVERS}" -- pin_dns
  msg_info "Waiting for network (DHCP + DNS)"
  wait_network || { msg_error "No network in container ${CTID}"; die "Check bridge, DHCP and VLAN."; }
  msg_ok "Network up: $(ct "$CTID" hostname -I | awk '{print $1}')"
}

# With isolation the LAN - including the router's DNS - is blocked. The
# container's DHCP client would replace the public resolvers in
# /etc/resolv.conf with the router's on every lease, breaking DNS a few
# seconds after start. Tell every DHCP client flavour to keep our servers.
pin_dns() {
  local servers; read -ra servers <<<"$DNS_SERVERS"
  ct "$CTID" bash -s -- "${servers[@]}" <<'PIN'
set -e
servers=("$@")
printf 'nameserver %s\n' "${servers[@]}" >/etc/resolv.conf
csv="$(IFS=,; echo "${servers[*]}")"
if [[ -d /etc/dhcp ]]; then   # isc-dhcp-client (dhclient)
  touch /etc/dhcp/dhclient.conf
  sed -i '/^supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
  echo "supersede domain-name-servers ${csv//,/, };" >>/etc/dhcp/dhclient.conf
fi
if [[ -f /etc/dhcpcd.conf ]] || command -v dhcpcd >/dev/null 2>&1; then   # dhcpcd
  touch /etc/dhcpcd.conf
  grep -q '^nooption domain_name_servers' /etc/dhcpcd.conf || echo 'nooption domain_name_servers' >>/etc/dhcpcd.conf
  grep -q '^static domain_name_servers' /etc/dhcpcd.conf || echo "static domain_name_servers=${servers[*]}" >>/etc/dhcpcd.conf
fi
if [[ -d /etc/systemd/network ]]; then   # systemd-networkd
  mkdir -p /etc/systemd/network/eth0.network.d
  printf '[DHCPv4]\nUseDNS=no\n[Network]\nDNS=%s\n' "${servers[*]}" >/etc/systemd/network/eth0.network.d/10-gha-dns.conf
fi
echo "resolv.conf now:"; cat /etc/resolv.conf
PIN
}

# Copy the repo into the CT: local checkout if we run from one, else git clone.
deploy_repo() {
  step "Updating container OS packages" "Updated container OS packages" \
    --status '^(Get|Unpacking|Setting up)' \
    -- ct "$CTID" bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y dist-upgrade && apt-get install -y git curl ca-certificates'
  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -n "$src_dir" && -f "${src_dir}/lxc/setup.sh" ]]; then
    step "Copying local checkout" "Deployed scripts from ${src_dir}" \
      -- bash -c "tar -C '$src_dir' -czf - . | pct exec '$CTID' -- ${CT_ENV[*]} bash -c 'mkdir -p ${CT_REPO_DIR} && tar -xzf - -C ${CT_REPO_DIR}'"
  else
    step "Downloading installer scripts" "Deployed scripts (${REPO_BRANCH})" \
      -- ct "$CTID" git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CT_REPO_DIR"
  fi
}

install_docker() {
  local rc=0
  msg_info "Installing Docker" '^==> '
  run ct "$CTID" bash "${CT_REPO_DIR}/lxc/setup.sh" docker || rc=$?
  if [[ "$rc" == 3 ]]; then
    msg_warn "Docker cannot start containers in this LXC (usually AppArmor on nested containers)"
    w_yesno "Docker could not run a test container.

Common fix on Proxmox: run the LXC with an unconfined AppArmor profile
(lxc.apparmor.profile: unconfined). This lowers isolation between the
container and the host.

Apply the fix and retry?" 1 || die "Docker not working - aborted."
    step "Stopping container ${CTID}" "Stopped container ${CTID}" -- pct stop "$CTID"
    echo "lxc.apparmor.profile: unconfined" >>"/etc/pve/lxc/${CTID}.conf"
    msg_ok "Applied AppArmor fix"
    start_ct
    step "Installing Docker (retry)" "Installed Docker" --status '^==> ' \
      -- ct "$CTID" bash "${CT_REPO_DIR}/lxc/setup.sh" docker
  elif [[ "$rc" == 0 ]]; then
    msg_ok "Installed Docker ($(ct "$CTID" docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'))"
  else
    msg_error "Installing Docker failed (exit ${rc})"
    show_log_tail
    exit "$rc"
  fi
}

# Phase 1 (per container): register runners right away - the pair code
# expires after 1 hour, and building images for several containers takes longer.
push_bootstrap() {   # uses CTID, CUR_PREFIX
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
}

register_runners() {   # uses CTID, CUR_PREFIX
  local rc
  while true; do
    push_bootstrap
    msg_info "Registering runner(s) with GitHub" '^(==> |√|Runner successfully)'
    rc=0
    run ct "$CTID" bash "${CT_REPO_DIR}/lxc/setup.sh" register /root/.gha-bootstrap.env || rc=$?
    if [[ "$rc" == 0 ]]; then
      local names; names="$(ct "$CTID" bash -c 'ls /etc/gha-runners/runners/ | sed -n "s/\.env$//p" | paste -sd, -')"
      local -a list; IFS=, read -ra list <<<"$names"
      REGISTERED_RUNNERS+=("${list[@]}")
      msg_ok "Registered runner(s): ${names}"
      return 0
    fi
    if [[ "$rc" == 4 ]]; then   # setup.sh: name already exists in GitHub
      msg_warn "A runner named '${CUR_PREFIX}...' already exists in GitHub"
      [[ "$NONINTERACTIVE" == 1 ]] && die "Choose another RUNNER_PREFIX."
      CUR_PREFIX="$(w_ask "A runner with this name already exists in GitHub.

Enter a different runner name:" "${CUR_PREFIX}-b" valid_name \
        "Letters, digits and '-', must start with a letter or digit." normalize_trim)"
      continue
    fi
    msg_error "Registering runner(s) failed (exit ${rc})"
    show_log_tail
    exit "$rc"
  done
}

runner_names_for() {   # runner_names_for <prefix>
  local n i out=(); n="$(runners_per_ct)"
  if (( n == 1 )); then echo "$1"; return; fi
  for ((i = 1; i <= n; i++)); do out+=("$1-$i"); done
  (IFS=', '; echo "${out[*]}")
}

provision_ct() {   # provision_ct <index>
  [[ "${PLAN_IDS[$1]}" == next ]] && PLAN_IDS[$1]="$(next_id)"
  CTID="${PLAN_IDS[$1]}" CUR_HOSTNAME="${PLAN_NAMES[$1]}" CUR_IP="${PLAN_IPS[$1]}" CUR_PREFIX="${PLAN_PREFIXES[$1]}"
  printf '\n %s[%s/%s] Container %s (%s)%s\n' "$BL" "$(( $1 + 1 ))" "$(ct_count)" "$CTID" "$CUR_HOSTNAME" "$CL"
  create_ct
  setup_firewall
  start_ct
  verify_isolation
  deploy_repo
  install_docker
  register_runners
}

# The containers and the GitHub registration are fine at this point, so a
# failed build must not throw them away: offer retry / standard / stop.
build_image() {   # build_image <ctid>
  local id="$1" rc choice
  while true; do
    msg_info "Building '${RUNNER_FLAVOR}' image (standard ~5-10 min, full ~20-40 min)" '.*### step '
    rc=0
    run ct "$id" /usr/local/bin/gha-runners build --flavor "$RUNNER_FLAVOR" || rc=$?
    if [[ "$rc" == 0 ]]; then msg_ok "Built runner image quavon/gha-runner:${RUNNER_FLAVOR}"; return 0; fi
    msg_error "Building '${RUNNER_FLAVOR}' image failed (exit ${rc})"
    show_log_tail
    [[ "$NONINTERACTIVE" == 1 ]] && exit "$rc"
    local alt=()
    [[ "$RUNNER_FLAVOR" == full ]] && alt=(standard "Use the 'standard' image instead (switch to full later: gha-runners build --flavor full)")
    choice="$(w_menu "The runner image could not be built (output above / in ${LOG_FILE}).

Container(s) and GitHub registration are fine." retry \
      retry "Try the build again" "${alt[@]}" stop "Stop the installation")"
    case "$choice" in
      retry) continue ;;
      standard) RUNNER_FLAVOR=standard ;;
      *) exit "$rc" ;;
    esac
  done
}

# Phase 2: build the image once, copy it to the other containers, start all.
finish_all() {
  local image="quavon/gha-runner:${RUNNER_FLAVOR}" first="${PLAN_IDS[0]}" id
  printf '\n %sRunner image%s\n' "$BL" "$CL"
  build_image "$first"
  image="quavon/gha-runner:${RUNNER_FLAVOR}"   # may have changed to standard
  for id in "${PLAN_IDS[@]:1}"; do
    msg_info "Copying image to container ${id}"
    if run bash -c "pct exec '$first' -- ${CT_ENV[*]} docker save '$image' | pct exec '$id' -- ${CT_ENV[*]} docker load"; then
      msg_ok "Copied image to container ${id}"
    else
      msg_warn "Copy to ${id} failed, building there instead"
      step "Building image in container ${id}" "Built image in container ${id}" --status '.*### step ' \
        -- ct "$id" /usr/local/bin/gha-runners build --flavor "$RUNNER_FLAVOR"
    fi
  done
  printf '\n %sStarting%s\n' "$BL" "$CL"
  for id in "${PLAN_IDS[@]}"; do
    step "Starting runners in container ${id}" "Started runners in container ${id}" \
      -- ct "$id" bash "${CT_REPO_DIR}/lxc/setup.sh" start
    wait_online "$id"
  done
}

# The runner prints "Listening for Jobs" once it is connected to GitHub.
wait_online() {   # wait_online <ctid>
  local id="$1" name names _ total online
  names="$(ct "$id" bash -c 'ls /etc/gha-runners/runners/ | sed -n "s/\.env$//p"')"
  total="$(wc -w <<<"$names")"
  msg_info "Waiting for runner(s) in ${id} to connect to GitHub"
  for _ in $(seq 1 45); do
    online=0
    for name in $names; do
      ct "$id" journalctl -u "gha-runner@${name}" --no-pager -n 200 2>/dev/null \
        | grep -q "Listening for Jobs" && online=$((online + 1))
    done
    if (( online == total )); then msg_ok "Online in GitHub: ${names//$'\n'/, }"; return 0; fi
    sleep 4
  done
  msg_warn "${online}/${total} runner(s) online after 3 min - check: pct exec ${id} -- /usr/local/bin/gha-runners logs <name>"
}

summary() {
  local i id ip rows=""
  for i in "${!PLAN_IDS[@]}"; do
    id="${PLAN_IDS[$i]}"
    ip="$(ct "$id" hostname -I | awk '{print $1}')"
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
their LXC. $(if [[ $NET_ISOLATION != internet ]]; then echo "They can reach your whole LAN."; elif ((${#NO_ISOLATION_CTS[@]})); then echo "Isolation was SKIPPED for CT ${NO_ISOLATION_CTS[*]}: jobs there can reach your LAN."; else echo "The host firewall keeps them off your LAN."; fi)
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
  printf ' %sLog: %s%s\n' "$DIM" "$LOG_FILE" "$CL"
  preflight
  msg_info "Asking Proxmox for the next free container ID"
  defaults
  msg_ok "Next free container ID: ${CTID}"
  w_yesno "This creates LXC container(s) with Docker and GitHub Actions runners.\n\nProceed?" 1 || exit_cancel
  ask_github
  msg_ok "GitHub target: ${GH_URL}"
  ask_settings
  confirm
  header
  [[ "$FANCY" == 1 ]] && tput civis 2>/dev/null
  printf ' %sLog: %s%s\n\n %sPreparation%s\n' "$DIM" "$LOG_FILE" "$CL" "$BL" "$CL"
  ensure_template
  local i
  for i in "${!PLAN_IDS[@]}"; do provision_ct "$i"; done
  finish_all
  summary
}

main "$@"
