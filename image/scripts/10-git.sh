#!/usr/bin/env bash
# flavors: standard full
# Latest git (git-core PPA, as on hosted runners), git-lfs and GitHub CLI.
source "$(dirname "$0")/lib.sh"

log "git + git-lfs"
add-apt-repository -y ppa:git-core/ppa
apt_install git git-lfs
git lfs install --system
git config --system --add safe.directory '*'

log "GitHub CLI"
add_apt_repo github-cli https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  "https://cli.github.com/packages stable main"
apt_install gh
