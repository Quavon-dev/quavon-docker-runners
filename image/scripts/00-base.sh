#!/usr/bin/env bash
# flavors: standard full
# Core OS packages, runner user, locale and tool cache - mirrors the base
# layer of GitHub's ubuntu-24.04 hosted image.
source "$(dirname "$0")/lib.sh"

log "Base packages"
apt_install \
  acl aria2 apt-transport-https autoconf automake bc binutils bison brotli \
  build-essential bzip2 ca-certificates cmake coreutils curl dbus dnsutils \
  dpkg-dev fakeroot file findutils flex fonts-noto-color-emoji ftp g++ gcc \
  gettext gnupg gpg-agent haveged iproute2 iputils-ping jq less \
  libcurl4-openssl-dev libgbm-dev libgtk-3-0t64 libicu-dev libkrb5-3 \
  libsecret-1-dev libsqlite3-dev libssl-dev libtool libunwind8 libxkbfile-dev \
  libxss1 libyaml-dev locales lsb-release lz4 m4 make mediainfo mercurial \
  net-tools netcat-openbsd ninja-build openssh-client p7zip-full parallel \
  patchelf pigz pkg-config python-is-python3 rpm rsync shellcheck \
  software-properties-common sqlite3 sshpass ssh subversion sudo swig tar \
  telnet texinfo time tk tree tzdata unzip upx-ucl vim-tiny wget xorriso \
  xvfb xz-utils zip zlib1g zstd zsync
is_amd64 && apt_install lib32z1

log "Locale"
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

log "Runner user (uid 1001, passwordless sudo - same as hosted runners)"
useradd -m -u 1001 -U -s /bin/bash runner
echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner
echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >>/etc/sudoers.d/runner
chmod 0440 /etc/sudoers.d/runner

log "Tool cache + env file"
install -d -o runner -g runner /opt/hostedtoolcache
install -d /etc/gha
: >"$GHA_ENV_FILE"
ln -sf "$GHA_ENV_FILE" /etc/profile.d/zz-gha.sh
add_env AGENT_TOOLSDIRECTORY /opt/hostedtoolcache
add_env RUNNER_TOOL_CACHE /opt/hostedtoolcache
