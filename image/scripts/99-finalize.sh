#!/usr/bin/env bash
# flavors: standard full full-plus
# Image metadata, ownership fix-ups and cleanup.
source "$(dirname "$0")/lib.sh"

log "Finalize"
add_env ImageOS ubuntu24
add_env ImageVersion "$(date -u +%Y%m%d).quavon"
add_env XDG_CONFIG_HOME /home/runner/.config
chown -R runner:runner /home/runner /opt/hostedtoolcache
apt-get clean
echo "--- /etc/gha/env.sh ---"
cat "$GHA_ENV_FILE"
