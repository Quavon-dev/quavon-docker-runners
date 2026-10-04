#!/usr/bin/env bash
# flavors: full full-plus
# PowerShell (pwsh) from the Microsoft repo, so `shell: pwsh` steps work.
source "$(dirname "$0")/lib.sh"

log "PowerShell"
if ! is_amd64; then
  echo "PowerShell apt package is amd64-only, skipping"
  exit 0
fi
. /etc/os-release
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o /tmp/ms.deb
dpkg -i /tmp/ms.deb
apt_install powershell
