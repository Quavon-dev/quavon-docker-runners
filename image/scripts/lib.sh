#!/usr/bin/env bash
# Shared helpers for image build steps. Sourced, never executed directly.
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

apt_install() {
  apt-get update -qq
  apt-get install -y --no-install-recommends "$@"
}

arch_deb() { dpkg --print-architecture; }            # amd64 | arm64

arch_alt() {                                         # x64 | arm64
  case "$(arch_deb)" in
    amd64) echo x64 ;;
    arm64) echo arm64 ;;
    *) die "unsupported architecture: $(arch_deb)" ;;
  esac
}

is_amd64() { [[ "$(arch_deb)" == amd64 ]]; }

# Latest release tag of a GitHub repo without touching the rate-limited API.
gh_latest_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")"
  [[ "$url" == */tag/* ]] || die "could not resolve latest release of $1"
  echo "${url##*/tag/}"
}

# add_apt_repo <name> <key-url> <deb-line-without-signed-by>
add_apt_repo() {
  local name="$1" key_url="$2" line="$3" keyring="/etc/apt/keyrings/$1.gpg"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$key_url" | gpg --dearmor --yes -o "$keyring"
  chmod a+r "$keyring"
  echo "deb [arch=$(arch_deb) signed-by=${keyring}] ${line}" >"/etc/apt/sources.list.d/${name}.list"
}

# Persist env for the runner process (sourced by the entrypoint) and for
# interactive shells (/etc/profile.d links to the same file).
GHA_ENV_FILE=/etc/gha/env.sh

add_env() {
  printf 'export %s=%q\n' "$1" "$2" >>"$GHA_ENV_FILE"
}

add_path() {
  printf 'export PATH=%q:"$PATH"\n' "$1" >>"$GHA_ENV_FILE"
}

as_runner() { sudo -u runner -H "$@"; }
