#!/usr/bin/env bash
# flavors: standard full full-plus
# Docker CLI + buildx + compose. Jobs talk to the LXC's Docker daemon via the
# mounted socket, so docker build/run, service containers and container jobs work.
source "$(dirname "$0")/lib.sh"

log "Docker CLI"
add_apt_repo docker https://download.docker.com/linux/ubuntu/gpg \
  "https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"
apt_install docker-ce-cli docker-buildx-plugin docker-compose-plugin
groupadd -f docker
usermod -aG docker runner
