#!/usr/bin/env bash
# flavors: standard full full-plus
# System Python + pip + pipx (pipx paths match hosted runners).
source "$(dirname "$0")/lib.sh"

log "Python"
apt_install python3 python3-dev python3-pip python3-venv pipx

install -d -o runner -g runner /opt/pipx /opt/pipx_bin
add_env PIPX_HOME /opt/pipx
add_env PIPX_BIN_DIR /opt/pipx_bin
add_path /opt/pipx_bin
