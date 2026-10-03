#!/usr/bin/env bash
# Builds a systemd Debian 13 container (stand-in for the LXC) and runs the
# in-container integration test with real Docker inside it.
set -euo pipefail
cd "$(dirname "$0")/../.."
docker build -q -t gha-lxc-test tests/lxc >/dev/null
docker rm -f gha-lxc-test >/dev/null 2>&1 || true
docker volume create gha-lxc-test-docker >/dev/null
docker volume create gha-lxc-test-containerd >/dev/null
docker run -d --name gha-lxc-test --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v gha-lxc-test-docker:/var/lib/docker -v gha-lxc-test-containerd:/var/lib/containerd \
  -v "$PWD":/src:ro gha-lxc-test >/dev/null
trap 'docker rm -f gha-lxc-test >/dev/null 2>&1' EXIT
sleep 5
docker exec -e GH_TEST_URL="${GH_TEST_URL:-}" -e GH_TEST_TOKEN="${GH_TEST_TOKEN:-}" gha-lxc-test bash /src/tests/lxc/integration.sh
