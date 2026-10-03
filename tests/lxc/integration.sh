#!/usr/bin/env bash
# Runs INSIDE the systemd test container: exercises lxc/setup.sh, gha-runners,
# the systemd units, the image build and the runner container for real.
# A real GitHub registration is optional (GH_TEST_URL + GH_TEST_TOKEN).
set -uo pipefail
REPO=/opt/quavon-docker-runners
pass=0 fail=0
ok()   { echo "ok   $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL $1"; fail=$((fail + 1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }

cp -r /src "$REPO"

# Test machine only: nested Docker on Docker Desktop can't use the containerd
# overlay snapshotter. setup.sh keeps an existing daemon.json, so set overlay2.
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'J'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" },
  "features": { "containerd-snapshotter": false }, "storage-driver": "overlay2" }
J

section "setup.sh docker"
bash "$REPO/lxc/setup.sh" docker >/tmp/docker.log 2>&1; rc=$?
chk "docker installed + test container ran (rc=$rc)" '[[ $rc == 0 ]]'
chk "docker daemon active" 'systemctl is-active --quiet docker'
chk "log rotation configured" 'grep -q max-size /etc/docker/daemon.json'

section "setup.sh register (with an invalid token: must fail cleanly)"
cat >/root/.gha-bootstrap.env <<B
GH_URL=https://github.com/quavon-dev/quavon-docker-runners
GH_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAA
GH_PAT=''
RUNNER_EPHEMERAL=0
RUNNER_PREFIX=itest
RUNNER_COUNT=2
RUNNER_LABELS=docker
RUNNER_GROUP=''
RUNNER_FLAVOR=standard
RUNNER_CPUS=2
RUNNER_MEM=2048
B
bash "$REPO/lxc/setup.sh" register /root/.gha-bootstrap.env >/tmp/register.log 2>&1; rc=$?
chk "invalid token -> non-zero exit (rc=$rc)" '[[ $rc != 0 && $rc != 4 ]]'
chk "bootstrap with token deleted" '[[ ! -e /root/.gha-bootstrap.env ]]'
chk "no half-registered runner dir left" '[[ ! -e /srv/gha-runners/itest-1/.runner && ! -d /srv/gha-runners/itest-1 ]]'
chk "token never printed by registration" '! grep -q "AAAAAAAAAAAAAAAAAAAAAAAAAAAA" /tmp/register.log'
chk "CLI + units installed" 'command -v gha-runners >/dev/null && [[ -f /etc/systemd/system/gha-runner@.service ]]'
chk "prune timer enabled" 'systemctl is-enabled --quiet gha-runners-prune.timer'
chk "runner user uid 1001" '[[ $(id -u runner) == 1001 ]]'
chk "config written" 'grep -q "RUNNER_IMAGE=quavon/gha-runner:standard" /etc/gha-runners/config.env'
chk "runner tarball downloaded + cached" 'ls /var/cache/gha-runners/actions-runner-linux-*.tar.gz >/dev/null 2>&1'
echo "     --- registration output (tail) ---"; tail -8 /tmp/register.log | sed 's/^/     /'

section "gha-runners build (real image build, standard)"
start=$SECONDS
gha-runners build --flavor standard >/tmp/build.log 2>&1; rc=$?
chk "image built in $((SECONDS - start))s (rc=$rc)" '[[ $rc == 0 ]] && docker image inspect quavon/gha-runner:standard >/dev/null'
[[ $rc == 0 ]] || tail -20 /tmp/build.log

section "runner service (real registration or simulated)"
name=itest-1 dir=/srv/gha-runners/itest-1
if [[ -n "${GH_TEST_TOKEN:-}" ]]; then
  GHA_TOKEN="$GH_TEST_TOKEN" gha-runners add --name "$name" --url "$GH_TEST_URL" --labels itest --no-start >/tmp/add.log 2>&1
  chk "registered with GitHub" '[[ -f $dir/.runner ]]'
else
  # simulate a registered runner: real binaries + fake registration files
  source <(sed -n "/^install_runner_binaries()/,/^}/p;/^latest_runner_version()/,/^}/p;/^runner_arch()/,/^}/p;/^info()/p;/^die()/p" /usr/local/bin/gha-runners)
  CACHE_DIR=/var/cache/gha-runners RUNNER_UID=1001 install_runner_binaries "$dir" >/dev/null
  echo '{"agentId":1,"agentName":"itest-1","serverUrl":"https://pipelinesghubeus1.actions.githubusercontent.com/x/","gitHubUrl":"https://github.com/quavon-dev/quavon-docker-runners","workFolder":"_work"}' >"$dir/.runner"
  chown -R 1001:1001 "$dir"
  install -d -m 0700 /etc/gha-runners/runners
  printf 'RUNNER_NAME=%s\nRUNNER_DIR=%s\nGITHUB_URL=https://github.com/quavon-dev/quavon-docker-runners\nRUNNER_LABELS=docker\nRUNNER_GROUP=\nRUNNER_EPHEMERAL=0\n' "$name" "$dir" >/etc/gha-runners/runners/$name.env
  chmod 600 /etc/gha-runners/runners/$name.env
fi
systemctl start "gha-runner@$name"
for _ in $(seq 1 30); do docker inspect "gha-$name" >/dev/null 2>&1 && break; sleep 1; done
insp="$(docker inspect "gha-$name" 2>/dev/null || true)"
chk "runner container started" 'docker ps --format "{{.Names}}" | grep -qx "gha-$name"'
chk "runs as uid 1001" 'grep -q "\"User\": \"1001:1001\"" <<<"$insp"'
chk "host network" 'grep -q "\"NetworkMode\": \"host\"" <<<"$insp"'
chk "docker socket mounted" 'grep -q "/var/run/docker.sock:/var/run/docker.sock" <<<"$insp"'
chk "runner dir at identical path" 'grep -q "\"$dir:$dir\"" <<<"$insp"'
chk "cpu/memory caps applied" 'grep -q "\"NanoCpus\": 2000000000" <<<"$insp" && grep -q "\"Memory\": 2147483648" <<<"$insp"'
chk "no PAT/token in container env" '! grep -qE "GITHUB_PAT|GHA_TOKEN" <<<"$insp"'
docker exec "gha-$name" bash -lc 'id; docker version --format "docker-cli {{.Client.Version}} / daemon {{.Server.Version}}"; sudo -n true && echo sudo-ok' >/tmp/inrunner.log 2>&1
chk "docker usable from runner container" 'grep -q "daemon" /tmp/inrunner.log'
chk "passwordless sudo in runner" 'grep -q sudo-ok /tmp/inrunner.log'
# the same-path trick: a job container mounts a path from the runner dir
docker exec "gha-$name" bash -c "mkdir -p $dir/_work/t && echo hello >$dir/_work/t/f && docker run --rm -v $dir/_work/t:/w busybox cat /w/f" >/tmp/samepath.log 2>&1
chk "container jobs see runner workspace (same-path mount)" 'grep -qx hello /tmp/samepath.log'
sleep 8
journalctl -u "gha-runner@$name" --no-pager -n 80 >/tmp/runner-journal.log
chk "env.sh captured image PATH for jobs" 'grep -q /opt/pipx_bin "$dir/.path"'
chk "runner process actually launched (Runner.Listener)" 'grep -qiE "Runner|Listener|Connected|credentials|Error" /tmp/runner-journal.log'
grep -iE "listening|connected|error|exception" /tmp/runner-journal.log | head -4 | sed 's/^/     /'

section "job hooks"
docker exec -e GITHUB_WORKSPACE="$dir/_work/t" "gha-$name" /opt/gha/hooks/job-started.sh >/dev/null 2>&1
chk "job-started hook empties workspace" '[[ -z "$(ls -A "$dir/_work/t" 2>/dev/null)" ]]'

section "CLI"
gha-runners list >/tmp/list.log 2>&1
chk "gha-runners list shows runner" 'grep -q "$name" /tmp/list.log'
gha-runners limits --cpus 1 --memory 1024 >/dev/null 2>&1
sleep 6
chk "limits change applied after restart" 'docker inspect gha-$name 2>/dev/null | grep -q "\"Memory\": 1073741824"'
if [[ -z "${GH_TEST_TOKEN:-}" ]]; then
  gha-runners remove "$name" </dev/null >/tmp/remove.log 2>&1
  chk "remove cleans up locally" '[[ ! -e $dir && ! -e /etc/gha-runners/runners/$name.env ]] && ! docker inspect gha-$name >/dev/null 2>&1'
fi

printf '\nlxc integration: %s passed, %s failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
