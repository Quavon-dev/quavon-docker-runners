# Quavon Docker Runners

One command on a Proxmox VE host gives you a Debian LXC with Docker and one or
more **GitHub Actions self-hosted runners**. Each runner is a Docker container
whose image is modeled on GitHub's hosted `ubuntu-24.04` runner.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)"
```

The wizard asks for:

1. **The pair code.** In GitHub, open **Settings → Actions → Runners → New self-hosted runner**
   (repo, organisation or enterprise) and paste the whole
   `./config.sh --url https://github.com/... --token XXXXX` line. URL and token are
   read from it. The token is valid for **1 hour**, and runners are registered
   before the image build so a slow build can't outlast the token.
2. **Runner mode.** See [Persistent vs. ephemeral](#persistent-vs-ephemeral).
3. **Image flavor** (`standard` or `full`).
4. **Container settings.** `default` is 4 cores, 8 GB RAM, DHCP on `vmbr0`. `advanced` lets you
   set the ID, hostname, resources, static IP, VLAN, SSH key and privileged mode.
5. **Runner count, name, labels** and, for orgs or enterprises, a **runner group**.

Then use it in a workflow:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, docker]
```

## What you get

| | |
|---|---|
| LXC | Debian 13 (falls back to 12), unprivileged, `nesting,keyctl,fuse`, starts on boot |
| Runners | official `actions/runner`, auto-updating, one systemd service per runner |
| Docker in jobs | `docker build/run`, `services:`, `container:` jobs, buildx, compose |
| Networking | `--network host`, so `services:` ports work on `localhost` like on hosted runners |
| Hosted-runner parity | user `runner` (uid 1001) with passwordless `sudo`, `/opt/hostedtoolcache`, `ImageOS=ubuntu24`, so `actions/setup-*` work |
| Cleanup | workspace wiped before each job, file ownership fixed after container jobs, daily Docker prune |

### Image flavors

| `standard` (~3 GB) | `full` (~13 GB), everything in standard plus |
|---|---|
| build-essential, cmake, ninja, git (latest) + LFS, gh | Go (latest), Temurin JDK 11/17/21/25, Maven, Gradle, Ant |
| Docker CLI + buildx + compose | .NET SDK 8/9/10 |
| Python 3 + pip + pipx | Rust (rustup, clippy, rustfmt) |
| Node.js 22 + npm, yarn, pnpm | Ruby + bundler, PHP + Composer |
| jq, yq, kubectl, helm, shellcheck, zip/7z/zstd … | clang/lld/lldb, gfortran, MySQL/PostgreSQL clients, ImageMagick |
| | PowerShell, Chrome + chromedriver, Firefox + geckodriver |
| | AWS CLI v2, Azure CLI, Google Cloud CLI, ansible, kind |

Change the flavor later with `gha-runners build --flavor full && gha-runners restart`.

## Persistent vs. ephemeral

| | Persistent (default) | Ephemeral |
|---|---|---|
| Needs | pair code only | fine-grained PAT: repo **Administration: write** or org **Self-hosted runners: write** |
| Between jobs | workspace wiped, container keeps running | runner re-registers, and every job gets a brand-new container from the image, like GitHub-hosted |

## Managing runners

Open the container with `pct enter <CTID>`, then:

```text
gha-runners list                        # runners and their state
gha-runners add                         # add another runner (asks for a new pair code)
gha-runners add --config "./config.sh --url ... --token ..." --labels gpu
gha-runners remove <name>               # deregister (asks for the removal token) and delete
gha-runners logs <name> -f              # live logs
gha-runners restart [name]              # restart one or all
gha-runners shell <name>                # shell inside a runner container
gha-runners build [--flavor full]       # rebuild the image
gha-runners update                      # pull latest scripts, rebuild, restart
```

Running the install one-liner *inside* an existing runner LXC also does an update.

## Non-interactive install

Every prompt has an environment variable:

```bash
NONINTERACTIVE=1 \
GH_URL=https://github.com/my-org GH_TOKEN=AAAA... \
RUNNER_COUNT=4 RUNNER_FLAVOR=full RUNNER_LABELS=docker,big \
CTID=150 CORES=8 RAM=16384 DISK=150 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)"
```

Other variables: `RUNNER_MODE=ephemeral` with `GH_PAT`, `RUNNER_PREFIX`, `RUNNER_GROUP`,
`CT_HOSTNAME`, `SWAP`, `BRIDGE`, `NET_IP` / `NET_GW`, `VLAN`, `SSH_KEYS`, `UNPRIVILEGED`,
`REPO_URL` / `REPO_BRANCH` (forks).

For a private fork, clone it on the Proxmox host and run `./install.sh`. The local
checkout is copied into the container and nothing is cloned.

## Security

> **Jobs can reach the LXC's Docker socket, which gives them root inside the
> LXC.** This is the usual trade-off for self-hosted runners with Docker. Do not
> attach these runners to **public** repositories that run workflows from fork
> pull requests.

- Registration tokens are only passed to `config.sh` and are not saved (the bootstrap file is deleted).
- Registration and removal tokens reach `config.sh` through the environment
  (`ACTIONS_RUNNER_INPUT_TOKEN`), so they never appear in `ps`.
- In ephemeral mode the PAT is kept in `/etc/gha-runners/runners/<name>.pat`
  (root, mode 600) and **never enters the runner container**. The LXC mints a
  1-hour registration token from it and passes in only that token, which is
  unset before the runner starts. Jobs still have root on the LXC through the
  Docker socket, so give the PAT the narrowest scope you can. For organisations,
  use a fine-grained PAT with only **Self-hosted runners: write**.
- If Docker can't start containers in the LXC (a known AppArmor issue on some PVE
  versions), the installer offers `lxc.apparmor.profile: unconfined`, but only
  after you confirm it.

## Layout

```text
install.sh                 Proxmox host wizard (pct create / push / exec)
lxc/setup.sh               provisioning inside the LXC (Docker, CLI, registration)
lxc/gha-runners            management CLI
lxc/run-container.sh       docker run wrapper used by gha-runner@.service
lxc/systemd/               runner template unit + daily prune timer
image/Dockerfile           runner image (FLAVOR=standard|full)
image/scripts/NN-*.sh      one build step per toolchain ("# flavors:" header)
image/entrypoint.sh        ephemeral re-registration, env capture, run.sh
image/hooks/               job-started / job-completed cleanup hooks
```
