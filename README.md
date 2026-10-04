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
3. **Image flavor** (`standard`, `full` or `full-plus`).
4. **Parallel jobs.** How many runners you want, and whether they share one LXC
   or each get their own (see [Parallel jobs](#parallel-jobs)).
5. **Size per runner** (`small` / `medium` / `large` / `xlarge` / `custom`;
   see [Sizing](#sizing)).
6. **Network access.** `internet` (default) blocks the LAN, or `lan` leaves it open
   (see [Network isolation](#network-isolation)).
7. **Container settings.** `default` uses the computed sizing and DHCP on `vmbr0`. `advanced`
   lets you set the ID, hostname, resources, static IP, VLAN, DNS, LAN exceptions, SSH key
   and privileged mode.
8. **Runner name, labels** and, for orgs or enterprises, a **runner group**.

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
| Network | internet only by default: LAN, Proxmox host and IPv6 blocked by the host firewall |
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

`full-plus` (~15 GB) is `full` plus a pinned backend/CI toolchain, so workflows don't
download or `go install` these on every run. Every download is checked against its
published SHA-256; the Go tools are built with `go install` at the exact tag.

| Tool | Version |
|---|---|
| bun | 1.3.14 |
| Valkey (`valkey-server`, `valkey-cli`; `redis-server`/`redis-cli` link to them) | 8.1.10 |
| nats-server | v2.14.6 |
| openfga | v1.19.0 |
| goose | v3.27.3 |
| OpenBao (`bao`) | 2.1.0 |
| Temporal CLI | 1.8.2 |
| TigerBeetle | 0.16.78 |
| typst | 0.15.1 |
| buf, protoc-gen-go, protoc-gen-connect-go | v1.47.2, v1.36.12, v1.20.0 |
| golangci-lint | v2.12.2 |
| gosec | v2.29.0 |
| gitleaks | 8.30.1 |
| actionlint | 1.7.12 |
| kubeconform | 0.8.0 |
| lsof | Ubuntu's |

Versions and digests live in `image/scripts/58-ci-stack.sh`. Valkey isn't started
as a service, so nothing holds port 6379.

**io_uring.** TigerBeetle needs io_uring, and Docker's default seccomp profile
blocks it. `full-plus` runners therefore run under Docker's default profile plus
`io_uring_setup`, `io_uring_enter` and `io_uring_register`
(`lxc/seccomp/io-uring.json`), never `unconfined`. io_uring has a history of kernel
bugs, so this widens the attack surface a little for jobs on these runners. To turn it
off, add `RUNNER_IO_URING=0` to `/etc/gha-runners/config.env` and run `gha-runners restart`.

Change the flavor later with `gha-runners build --flavor full && gha-runners restart`
(or `--flavor full-plus`).

Invalid input never aborts the wizard: the prompt explains what's wrong and asks
again. Labels are cleaned up automatically, so `docker, linux` becomes `docker`
(`linux` is a built-in label).

Like the Proxmox helper scripts, the installer takes the next free container ID
from Proxmox and doesn't look at your other guests. If the runner name is already
taken in GitHub, it asks you for another name and retries. An existing runner is
never replaced silently.

Every step shows a spinner with what's running and how long it has taken, then a
✔. Long steps (OS update, Docker, image build) show their current sub-step. All
command output goes to `/tmp/gha-runners-install-<date>.log`. If a step fails,
you get a ✖ plus that step's output. `VERBOSE=1` shows all output live, and
`DEBUG=1` adds a shell trace in `/tmp/gha-install.log`.

## Parallel jobs

A runner executes **one job at a time**. *N* runners means *N* jobs at once, and
any further jobs wait in GitHub's queue. You choose where the runners live:

| Layout | What you get | Use when |
|---|---|---|
| `shared` (default) | 1 LXC, *N* runners, one Docker, disk and image | trusted repos; least overhead |
| `separate` | *N* LXCs, 1 runner each, each with its own firewall and Docker | untrusted or mixed repos; jobs fully isolated from each other |

`separate` costs about 0.5 GB of RAM plus one image copy (~3, ~13 or ~15 GB of disk)
per extra container. The image is built only once and copied to the others. All
runners are registered before the build, so the 1-hour pair code doesn't expire.
With a static IP, the address is counted up per container (`.50`, `.51`, …).

## Network isolation

By default the container can reach **the internet only**. It cannot reach your LAN,
the Proxmox host, your router, other VMs and containers, or anything over IPv6, and
nothing can connect into it. Jobs still have full access to GitHub, package
registries and Docker Hub.

The rules are enforced by the **Proxmox firewall on the host**, on the container's
network interface. Rules inside the container would be useless because jobs
effectively have root there.

| Rule | Effect |
|---|---|
| inbound policy `DROP` | no connections into the container (`pct enter` still works) |
| `REJECT` to 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, multicast | LAN, CGNAT and link-local blocked |
| `REJECT` to the Proxmox host's own IPs | host blocked even if it has public addresses |
| `REJECT` all IPv6 | LAN devices with global IPv6 addresses can't be reached |
| DNS via `1.1.1.1` / `9.9.9.9` | a LAN resolver isn't needed |
| `ACCEPT` to `LAN_ALLOW` entries | opt-in exceptions, e.g. an internal registry or GitHub Enterprise Server |

The installer checks that this works: `github.com` must be reachable, and the
Proxmox web UI (`:8006`) and the gateway must not be. If either check fails, it aborts.

**Datacenter firewall:** guest firewalls only apply when the datacenter firewall
is on. If it's off, the installer asks before turning it on with input policy
`ACCEPT`, so the host and other guests behave exactly as before. If the
datacenter firewall is off but already has a `DROP` input policy configured, the
installer warns you first, because turning it on could lock you out of the web UI or SSH.

Rules live in `/etc/pve/firewall/<CTID>.fw` on the host. You can also view them in
the UI under **CT → Firewall**. For even stronger separation, put the container on
its own VLAN (advanced settings).

## Sizing

Choose a **per-runner size**. Each runner container is capped at that size, so
one heavy job can't starve the others. The LXC totals are computed from the size
and the runner count:

| Preset | CPU / runner | RAM / runner | Job disk / runner | Good for |
|---|---|---|---|---|
| `small` | 1 | 2 GB | 4 GB | lint, unit tests, small builds |
| `medium` (default) | 2 | 4 GB | 6 GB | typical web and app builds |
| `large` | 4 | 8 GB | 10 GB | Docker image builds, big test suites |
| `xlarge` | 8 | 16 GB | 20 GB | heavy compiles (Rust, C++, Android) |
| `custom` | you choose | you choose | you choose | |

LXC totals:
- **CPU:** runners × CPU, capped at the host's cores.
- **RAM:** runners × RAM, plus 1 GB for the OS.
- **Disk:** 2 GB OS, plus the image (`standard` ~3 GB, `full` ~13 GB, `full-plus` ~15 GB), plus runners × (1 GB + job disk).

For example, 2 × `medium` with `standard` gives 4 cores, 9 GB RAM and 19 GB disk.
In advanced mode you can override every total.

CPU and RAM are **limits, not reservations**: an idle runner uses about 150 MB.
On LVM-thin and ZFS the disk is thin-provisioned, so only data actually written
takes space. Unused job images are pruned daily.

Change limits later:

```text
gha-runners limits                          # show (inside the LXC)
gha-runners limits --cpus 4 --memory 8192   # per-runner caps, restarts runners (0 = unlimited)
pct set <CTID> --cores 8 --memory 16384     # LXC totals (on the Proxmox host)
pct resize <CTID> rootfs +10G               # grow the disk (on the Proxmox host)
```

Containers that a job starts itself (`docker run`, `services:`) are bounded by the
LXC totals, not by the per-runner cap.

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
gha-runners build [--flavor F]          # rebuild the image
gha-runners limits [--cpus N --memory MB]  # per-runner CPU/RAM caps
gha-runners update                      # pull latest scripts, rebuild, restart
```

Running the install one-liner *inside* an existing runner LXC also does an update.

## Non-interactive install

Every prompt has an environment variable:

```bash
NONINTERACTIVE=1 \
GH_URL=https://github.com/my-org GH_TOKEN=AAAA... \
RUNNER_COUNT=4 SIZE=large RUNNER_FLAVOR=full RUNNER_LABELS=docker,big \
CTID=150 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)"
```

Other variables: `LAYOUT=shared|separate`, `SIZE=custom` with `RUNNER_CPUS` / `RUNNER_MEM`, `CORES` / `RAM` / `DISK`
(override the totals), `NET_ISOLATION=internet|lan`, `DNS_SERVERS`, `LAN_ALLOW=10.0.0.5,10.0.10.0/24`,
`RUNNER_MODE=ephemeral` with `GH_PAT`, `RUNNER_PREFIX`, `RUNNER_GROUP`,
`CT_HOSTNAME`, `SWAP`, `BRIDGE`, `NET_IP` / `NET_GW`, `VLAN`, `SSH_KEYS`, `UNPRIVILEGED`,
`REPO_URL` / `REPO_BRANCH` (forks).

For a private fork, clone it on the Proxmox host and run `./install.sh`. The local
checkout is copied into the container and nothing is cloned.

## Security

> **Jobs can reach the LXC's Docker socket, which gives them root inside the
> LXC.** This is the usual trade-off for self-hosted runners with Docker.
> [Network isolation](#network-isolation) stops a compromised job from reaching
> the rest of your network, but it can still use the internet. Do not attach
> these runners to **public** repositories that run workflows from fork pull
> requests.

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

## Tests

Everything runs in Docker on any machine. No Proxmox host is needed.

```bash
tests/run.sh         # shellcheck + unit tests + 17 end-to-end wizard runs
tests/lxc/run.sh     # inside-the-LXC side for real: Docker, systemd units, image build, runner container
```

- **End-to-end tests** start `install.sh` exactly like the one-liner (`bash -c "$(…)"`) against a
  fake Proxmox (`tests/fake-pve/`), and type into the real whiptail dialogs through a
  pseudo-terminal. They cover:
  - the normal path, the `separate` layout with static IPs and VLAN, LAN mode, and ephemeral mode
  - invalid input, runner-name clashes, and a disabled datacenter firewall
  - Docker or AppArmor failures, a leaky firewall, and no network
  - Esc and Ctrl+C, a too-small terminal, a hanging `pvesh`, and non-interactive mode

  They also check that no token ever appears in a command line or the log.
- **LXC integration** boots Debian 13 with systemd and runs the real `setup.sh`,
  `gha-runners`, systemd units and image build. With `GH_TEST_URL` and `GH_TEST_TOKEN`
  set, it also registers a real runner.

## Layout

```text
install.sh                 Proxmox host wizard (pct create / push / exec)
lxc/setup.sh               provisioning inside the LXC (Docker, CLI, registration)
lxc/gha-runners            management CLI
lxc/run-container.sh       docker run wrapper used by gha-runner@.service
lxc/systemd/               runner template unit + daily prune timer
lxc/seccomp/io-uring.json  seccomp profile for full-plus runners (Docker default + io_uring)
image/Dockerfile           runner image (FLAVOR=standard|full|full-plus)
image/scripts/NN-*.sh      one build step per toolchain ("# flavors:" header)
image/entrypoint.sh        ephemeral re-registration, env capture, run.sh
image/hooks/               job-started / job-completed cleanup hooks
tests/                     unit + end-to-end tests (fake Proxmox) and LXC integration test
```
