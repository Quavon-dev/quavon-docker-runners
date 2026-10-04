#!/usr/bin/env bash
# flavors: full full-plus
# Latest stable Go.
source "$(dirname "$0")/lib.sh"

version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
log "Go ${version}"
curl -fsSL "https://go.dev/dl/${version}.linux-$(arch_deb).tar.gz" | tar -xz -C /usr/local
add_path /usr/local/go/bin
add_path /home/runner/go/bin
