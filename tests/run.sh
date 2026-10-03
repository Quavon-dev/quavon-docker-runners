#!/usr/bin/env bash
# Runs the whole test suite in a Debian 13 container (same base as Proxmox VE 9).
#   tests/run.sh            all tests
#   tests/run.sh e2e NAME   one e2e case, e.g. tests/run.sh e2e happy_shared
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== shellcheck"
shellcheck install.sh lxc/*.sh lxc/gha-runners image/*.sh image/hooks/*.sh image/scripts/*.sh tests/*.sh tests/fake-pve/bin/{pct,pvesh,pvesm,pveam,ip}
echo "ok"

docker run --rm -v "$PWD":/src:ro debian:13 bash -c '
  set -e
  apt-get update -qq >/dev/null
  apt-get install -y -qq whiptail python3-pexpect iproute2 procps bsdextrautils ncurses-bin >/dev/null 2>&1
  if [[ "${1:-}" != e2e ]]; then echo "== unit"; bash /src/tests/unit.sh; fi
  echo "== e2e"; shift || true; python3 /src/tests/e2e.py "$@"
' _ "$@"
