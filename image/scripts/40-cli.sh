#!/usr/bin/env bash
# flavors: standard full
# Common CLIs: yq, kubectl, helm.
source "$(dirname "$0")/lib.sh"

log "yq"
curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(arch_deb)" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

log "kubectl"
k8s_minor="$(curl -fsSL https://dl.k8s.io/release/stable.txt | cut -d. -f1,2)"
add_apt_repo kubernetes "https://pkgs.k8s.io/core:/stable:/${k8s_minor}/deb/Release.key" \
  "https://pkgs.k8s.io/core:/stable:/${k8s_minor}/deb/ /"
apt_install kubectl

log "helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
