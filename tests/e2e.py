#!/usr/bin/env python3
"""End-to-end tests for install.sh against a fake Proxmox host.

Drives the real whiptail dialogs through a pseudo-terminal (pexpect), the same
way a user does, and checks what the installer did to the (fake) host.
Run via tests/run.sh, which provides the Docker environment.
"""
import os
import re
import shutil
import subprocess
import sys
import time

import pexpect

ROOT = "/src"
FAKE_BIN = f"{ROOT}/tests/fake-pve/bin"
STATE = "/tmp/fake-state"
TOKEN = "AAAABBBBCCCCDDDDEEEEFFFF1234"
PAT = "github_pat_TESTONLY_0123456789abcdef"
PASTE = f"./config.sh --url https://github.com/quavon-dev --token {TOKEN}"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0B]|\r")

ENTER, ESC, TAB, CTRL_C = "\r", "\x1b", "\t", "\x03"
CLEAR = "\x7f" * 70  # wipe a pre-filled input box

results = []


# --------------------------------------------------------------- helpers --
def reset_host(cluster_fw=True, flags=()):
    shutil.rmtree(STATE, ignore_errors=True)
    os.makedirs(STATE)
    for f in flags:
        open(f"{STATE}/flag.{f}", "w").close()
    shutil.rmtree("/etc/pve", ignore_errors=True)
    os.makedirs("/etc/pve/firewall")
    os.makedirs("/etc/pve/lxc")
    if cluster_fw:
        with open("/etc/pve/firewall/cluster.fw", "w") as fh:
            fh.write("[OPTIONS]\nenable: 1\n")
    for f in os.listdir("/tmp"):
        if f.startswith("gha-runners-install-"):
            os.remove(f"/tmp/{f}")


def env(**extra):
    e = dict(os.environ)
    e.update(PATH=f"{FAKE_BIN}:/usr/sbin:/usr/bin:/sbin:/bin", TERM="xterm",
             FAKE_STATE=STATE, LANG="C.UTF-8")
    e.update({k: str(v) for k, v in extra.items()})
    return e


def spawn(rows=40, cols=120, **extra):
    """Start the installer exactly like the README one-liner: bash -c "$(curl ...)"."""
    script = open(f"{ROOT}/install.sh").read()
    return pexpect.spawn("bash", ["-c", script], cwd="/tmp", env=env(**extra),
                         dimensions=(rows, cols), encoding="utf-8",
                         codec_errors="replace", timeout=60)


def drive(child, answers, until=pexpect.EOF, timeout=120):
    """Answer dialogs: answers = [(regex, keys | callable), ...] until `until`."""
    patterns = [a[0] for a in answers] + [until, pexpect.TIMEOUT]
    if until is not pexpect.EOF:
        patterns.append(pexpect.EOF)
    seen = []
    deadline = time.time() + timeout
    while time.time() < deadline:
        i = child.expect(patterns, timeout=max(1, deadline - time.time()))
        if i == len(answers):
            return seen
        if i == len(answers) + 1:
            raise AssertionError(f"timeout; dialogs answered: {seen}\nlast screen:\n{clean(child.before)[-1500:]}")
        if i == len(answers) + 2:
            tail = clean(child.logfile_read.getvalue() if child.logfile_read else child.before)[-1200:]
            raise AssertionError(f"installer exited early; dialogs answered: {seen}\nlast output:\n{tail}")
        pat, keys = answers[i]
        seen.append(pat)
        time.sleep(0.15)
        child.send(keys(seen) if callable(keys) else keys)
    raise AssertionError("drive() deadline exceeded")


def finish(child, timeout=120):
    child.expect(pexpect.EOF, timeout=timeout)
    child.close()
    return child.exitstatus if child.exitstatus is not None else 128 + (child.signalstatus or 0)


def clean(text):
    return ANSI.sub("", text or "")


def transcript(child):
    return clean(child.logfile_read.getvalue()) if child.logfile_read else ""


def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def calls():
    return read(f"{STATE}/calls")


def install_log():
    logs = [f for f in os.listdir("/tmp") if f.startswith("gha-runners-install-")]
    return read(f"/tmp/{logs[0]}") if logs else ""


class Capture:
    """Collects everything the terminal showed."""
    def __init__(self):
        self.buf = []

    def write(self, s):
        self.buf.append(s)

    def flush(self):
        pass

    def getvalue(self):
        return "".join(self.buf)


def run_case(name, fn):
    t0 = time.time()
    try:
        fn()
        results.append((name, True, ""))
        print(f"ok   {name} ({time.time() - t0:.0f}s)", flush=True)
    except Exception as exc:  # noqa: BLE001 - report every failure
        results.append((name, False, str(exc)))
        print(f"FAIL {name}: {exc}", flush=True)


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


# Default answers for a straight run through the wizard (accept defaults).
def wizard(labels="docker, linux", count="2", extra=()):
    return list(extra) + [
        (r"Proceed\?", ENTER),
        (r"Paste the whole", PASTE + ENTER),
        (r"Runner mode", ENTER),
        (r"Runner image", ENTER),
        (r"AT THE SAME TIME", CLEAR + count + ENTER),
        (r"Where should the", ENTER),
        (r"Resources PER RUNNER", ENTER),
        (r"Network access for jobs", ENTER),
        (r"Container settings", ENTER),
        (r"Runner name as shown", ENTER),
        (r"Extra labels", CLEAR + labels + ENTER),
        (r"Runner group", ENTER),
        (r"Ready to create", ENTER),
    ]


def new_child(**kw):
    child = spawn(**kw)
    child.logfile_read = Capture()
    return child


def assert_no_secret_leak():
    check(TOKEN not in calls(), "token appears in a command line (pct/pvesh args)")
    check(PAT not in calls(), "PAT appears in a command line")
    check(TOKEN not in install_log(), "token written to the install log")
    check(PAT not in install_log(), "PAT written to the install log")


# ----------------------------------------------------------------- cases --
def case_happy_shared():
    reset_host()
    c = new_child()
    drive(c, wizard(), until=r"are online")
    rc = finish(c)
    out = transcript(c)
    check(rc == 0, f"exit {rc}\n{out[-2000:]}")
    for line in ["Proxmox VE 9.1.2 host", "Next free container ID: 100", "GitHub target: https://github.com/quavon-dev",
                 "Updated LXC template list", "Downloaded template debian-13-standard", "Created LXC 100",
                 "Firewall rules: internet only", "Network up", "Isolation verified", "Updated container OS packages",
                 "Deployed scripts", "Installed Docker (29.8.2)", "Registered runner(s): gha-runners-1,gha-runners-2",
                 "Built runner image", "Started runners in container 100", "Online in GitHub"]:
        check(f"✔ {line}" in out, f"missing check mark: {line}")
    check("✖" not in out, "unexpected failure mark")
    create = read(f"{STATE}/ct-100.create")
    for arg in ["--cores\n4", "--memory\n9216", "local-lvm:19", "nesting=1,keyctl=1,fuse=1",
                "--unprivileged\n1", "firewall=1", "--nameserver\n1.1.1.1 9.9.9.9", "github-runner"]:
        check(arg in create, f"pct create missing {arg!r}")
    fw = read("/etc/pve/firewall/100.fw")
    check("policy_in: DROP" in fw and "OUT REJECT -dest +lan_block" in fw and "8000::/1" in fw, "firewall rules wrong")
    boot = read(f"{STATE}/ct-100-bootstrap")
    check("RUNNER_LABELS=docker\n" in boot, f"labels not normalized: {boot}")
    check("RUNNER_COUNT=2" in boot and "RUNNER_CPUS=2" in boot and "RUNNER_MEM=4096" in boot, "bootstrap sizing wrong")
    check(read(f"{STATE}/ct-100-runners").split() == ["gha-runners-1", "gha-runners-2"], "runners not registered")
    check("git clone" in calls(), "curl-style run should git clone the repo")
    check("pct exec 100 -- bash -s -- 1.1.1.1 9.9.9.9" in calls(), "public DNS not pinned against DHCP overwrite")
    check(re.search(r"pveam download \S+ debian-13-standard_13\.1-2_amd64\.tar\.zst", calls()) and "arm64" not in create,
          "must pick the template for the host architecture (amd64), not the newer arm64 one")
    assert_no_secret_leak()


def case_invalid_inputs_reprompt():
    reset_host()
    c = new_child()
    answers = [
        (r"Proceed\?", ENTER),
        (r"Could not find a GitHub URL", ENTER),
        (r"That value can't be used", ENTER),
        (r"Paste the whole", lambda seen: ("hello world" if seen.count(r"Paste the whole") == 1 else CLEAR + PASTE) + ENTER),
        (r"Runner mode", ENTER),
        (r"Runner image", ENTER),
        (r"AT THE SAME TIME", lambda seen: CLEAR + ("abc" if seen.count(r"AT THE SAME TIME") == 1 else "40" if seen.count(r"AT THE SAME TIME") == 2 else "1") + ENTER),
        (r"Resources PER RUNNER", ENTER),
        (r"Network access for jobs", ENTER),
        (r"Container settings", ENTER),
        (r"Runner name as shown", lambda seen: CLEAR + ("-bad" if seen.count(r"Runner name as shown") == 1 else "ci") + ENTER),
        (r"Extra labels", lambda seen: CLEAR + ("bad label!" if seen.count(r"Extra labels") == 1 else " gpu , docker,GPU") + ENTER),
        (r"Runner group", ENTER),
        (r"Ready to create", ENTER),
    ]
    seen = drive(c, answers, until=r"are online")
    rc = finish(c)
    check(rc == 0, f"exit {rc}")
    check(seen.count(r"That value can't be used") == 4, f"expected 4 re-prompts, saw {seen.count(r'That value can' + chr(39) + 't be used')}")
    check(seen.count(r"Could not find a GitHub URL") == 1, "bad URL not re-prompted")
    boot = read(f"{STATE}/ct-100-bootstrap")
    check("RUNNER_PREFIX=ci" in boot and "RUNNER_LABELS=gpu\\,docker" in boot or "RUNNER_LABELS=gpu,docker" in boot,
          f"inputs not applied: {boot}")
    check("RUNNER_COUNT=1" in boot, "count not applied")


def case_separate_static_ip():
    reset_host(flags=["two-storages"])
    open(f"{STATE}/ids", "w").write("100\n101\n")  # IDs already used on the host
    c = new_child()
    adv = {
        r"Container ID": ENTER, r"Hostname": ENTER, r"CPU cores per container": ENTER,
        r"RAM per container": ENTER, r"Swap per container": ENTER, r"Disk per container": ENTER,
        r"Network bridge": ENTER, r"IPv4: 'dhcp'": CLEAR + "192.168.1.50/24" + ENTER,
        r"IPv4 gateway": "192.168.1.1" + ENTER, r"VLAN tag": "20" + ENTER, r"SSH public key": ENTER,
        r"Public DNS servers": ENTER, r"LAN exceptions": "10.0.0.5" + ENTER, r"Unprivileged container": ENTER,
        r"Storage for the container disk": "\x1b[B" + ENTER,   # pick 2nd storage (tank)
        r"Storage for container templates": ENTER,
    }
    answers = [(k, v) for k, v in adv.items()] + [
        (r"Where should the", "\x1b[B" + ENTER),                # separate
        (r"Container settings", "\x1b[B" + ENTER),              # advanced
    ] + [a for a in wizard(count="3") if a[0] not in (r"Where should the", r"Container settings")]
    drive(c, answers, until=r"are online", timeout=240)
    rc = finish(c)
    out = transcript(c)
    check(rc == 0, f"exit {rc}\n{out[-2500:]}")
    ids = read(f"{STATE}/ids").split()
    check(ids == ["100", "101", "102", "103", "104"], f"CT ids wrong: {ids}")
    for n, (ctid, ip) in enumerate([("102", "192.168.1.50"), ("103", "192.168.1.51"), ("104", "192.168.1.52")], 1):
        create = read(f"{STATE}/ct-{ctid}.create")
        check(f"gha-runners-{n}" in create and f"ip={ip}/24,gw=192.168.1.1,tag=20,firewall=1" in create and "tank:" in create,
              f"CT {ctid} create args wrong:\n{create}")
        check(read(f"{STATE}/ct-{ctid}-runners").split() == [f"gha-runners-{n}"], f"CT {ctid} runner wrong")
        check(os.path.exists(f"{STATE}/ct-{ctid}-image"), f"image missing in {ctid}")
        check("10.0.0.5" in read(f"/etc/pve/firewall/{ctid}.fw"), "LAN exception missing")
    check(calls().count("gha-runners build") == 1, "image must be built once and copied")
    check("Copied image to container 103" in out and "Copied image to container 104" in out, "image copy not shown")


def case_name_clash_retry():
    reset_host(flags=["clash-once"])
    c = new_child()
    drive(c, wizard(extra=[(r"already exists in GitHub", CLEAR + "ci-b" + ENTER)]), until=r"are online")
    rc = finish(c)
    out = transcript(c)
    check(rc == 0, f"exit {rc}")
    check("⚠ A runner named" in out, "clash warning not shown")
    check(read(f"{STATE}/ct-100-runners").split() == ["ci-b-1", "ci-b-2"], f"retry names wrong: {read(f'{STATE}/ct-100-runners')}")


def case_docker_failure_shows_cause_and_cleans_up():
    reset_host(flags=["docker-fail"])
    c = new_child()
    drive(c, wizard() + [(r"Destroy the container", "\t" + ENTER)])   # Tab -> Yes
    rc = c.exitstatus if c.isalive() is False else finish(c)
    out = transcript(c)
    check(rc not in (0, None), "should fail")
    check("✖ Installing Docker failed" in out, "no failure mark")
    check("Unable to locate package docker-ce" in out, "failed step output not shown")
    check("Full log:" in out, "log path not shown")
    check("destroyed 100" in read(f"{STATE}/destroyed"), "half-built CT not destroyed after Yes")


def case_failure_keep_container():
    reset_host(flags=["docker-fail"])
    c = new_child()
    drive(c, wizard() + [(r"Destroy the container", ENTER)])   # Enter = No (keep)
    finish(c)
    check("Kept for debugging: 100" in transcript(c), "keep message missing")
    check(read(f"{STATE}/destroyed") == "", "container destroyed although user kept it")


def case_apparmor_fallback():
    reset_host(flags=["apparmor"])
    c = new_child()
    drive(c, wizard(extra=[(r"Apply the fix and retry", ENTER)]), until=r"are online")
    rc = finish(c)
    check(rc == 0, f"exit {rc}")
    check("lxc.apparmor.profile: unconfined" in read("/etc/pve/lxc/100.conf"), "apparmor fix not written")
    check("✔ Installed Docker" in transcript(c), "docker not installed after retry")


def case_ctrl_c_during_build():
    reset_host()
    c = new_child()
    drive(c, wizard(), until=r"Building 'standard' image")
    time.sleep(0.5)
    c.send(CTRL_C)
    drive(c, [(r"Destroy the container", ENTER)])
    rc = finish(c, timeout=30)
    out = transcript(c)
    check(rc == 130, f"exit {rc}, want 130")
    check("✖ Interrupted" in out, "interrupt message missing")
    check("Kept for debugging: 100" in out, "cleanup dialog not handled")
    check("Started runners" not in out, "continued after Ctrl+C")


def case_ctrl_c_in_dialog_and_esc():
    reset_host()
    c = new_child()
    drive(c, [(r"Proceed\?", ESC)])
    rc = finish(c, timeout=20)
    check(rc == 130 and "Cancelled by user" in transcript(c), f"Esc: exit {rc}")
    reset_host()
    c = new_child()
    # whiptail runs the terminal in raw mode: Ctrl+C is just a key there, Esc cancels.
    drive(c, [(r"Proceed\?", ENTER), (r"Paste the whole", ESC)])
    rc = finish(c, timeout=20)
    check(rc == 130 and "Cancelled by user" in transcript(c), f"Esc in 2nd dialog: exit {rc}")
    check("Esc = cancel" in transcript(c), "dialogs must say how to cancel")
    check(not os.path.exists(f"{STATE}/ct-100.create"), "container created after cancel")


def case_small_terminal():
    reset_host()
    c = new_child(rows=20, cols=70)
    rc = finish(c, timeout=20)
    check(rc == 1 and "need at least 80x24" in transcript(c), f"small terminal: exit {rc}")


def case_pvesh_hang_times_out():
    reset_host(flags=["pvesh-hang"])
    c = new_child(PVE_TIMEOUT=3)
    rc = finish(c, timeout=30)
    out = transcript(c)
    check(rc == 1 and "did not answer within 3s" in out, f"hang not reported: exit {rc}\n{out[-800:]}")


def case_firewall_off_dialog():
    reset_host(cluster_fw=False)
    c = new_child()
    drive(c, wizard(extra=[(r"datacenter firewall, which is OFF", ENTER)]), until=r"are online")
    rc = finish(c)
    check(rc == 0, f"exit {rc}")
    check("pvesh set /cluster/firewall/options --enable 1 --policy_in ACCEPT" in calls(), "firewall not enabled safely")


def case_isolation_must_hold():
    reset_host(flags=["leaky-firewall"])
    c = new_child()
    drive(c, wizard() + [(r"does NOT block the LAN", "a" + ENTER), (r"Destroy the container", ENTER)], timeout=200)
    finish(c)
    out = transcript(c)
    check("Isolation check failed" in out and "REACHABLE" in out, "leaky firewall not detected")
    check("Diagnostics:" in out, "diagnostics summary not shown")
    check("setup.sh docker" not in calls(), "continued installing despite failed isolation")


def case_isolation_unverifiable_continue_without():
    """Reporter's case: DNS works but TCP to github is blocked with the rules on."""
    reset_host(flags=["no-internet"])
    c = new_child()
    drive(c, wizard() + [(r"cannot reach github.com:443", "l" + ENTER)], until=r"are online", timeout=240)
    rc = finish(c)
    out = transcript(c)
    check(rc == 0, f"exit {rc}")
    check("Continuing without network isolation for CT 100" in out, "skip not confirmed")
    check(not os.path.exists("/etc/pve/firewall/100.fw"), "rules not removed after choosing to continue")
    check("Isolation was SKIPPED for CT 100" in out, "summary must warn that isolation is off")
    check("=== isolation diagnostics" in install_log(), "diagnostics not written to the log")


def case_lan_mode_and_ephemeral():
    reset_host()
    c = new_child()
    answers = wizard()
    answers = [(p, ("\x1b[B" + ENTER) if p in (r"Runner mode", r"Network access for jobs") else k) for p, k in answers]
    answers.append((r"Personal access token", PAT + ENTER))
    drive(c, answers, until=r"are online")
    rc = finish(c)
    check(rc == 0, f"exit {rc}")
    create = read(f"{STATE}/ct-100.create")
    check("firewall=1" not in create and "--nameserver" not in create, "lan mode must not add firewall/DNS")
    check(not os.path.exists("/etc/pve/firewall/100.fw"), "lan mode wrote firewall rules")
    boot = read(f"{STATE}/ct-100-bootstrap")
    check("RUNNER_EPHEMERAL=1" in boot and PAT in boot, "ephemeral bootstrap wrong")
    assert_no_secret_leak()


def case_no_network():
    reset_host(flags=["no-network"])
    c = new_child()
    drive(c, wizard() + [(r"Destroy the container", ENTER)], timeout=200)
    finish(c)
    check("No network in container 100" in transcript(c), "no-network not reported")


def case_noninteractive():
    reset_host()
    r = subprocess.run(["bash", "-c", open(f"{ROOT}/install.sh").read()], cwd="/tmp", capture_output=True, text=True,
                       timeout=200, env=env(NONINTERACTIVE=1, GH_URL="https://github.com/quavon-dev/app",
                                            GH_TOKEN=TOKEN, RUNNER_COUNT=3, LAYOUT="separate", SIZE="small",
                                            RUNNER_LABELS="docker , ci"))
    out = clean(r.stdout + r.stderr)
    check(r.returncode == 0, f"exit {r.returncode}\n{out[-2000:]}")
    check(read(f"{STATE}/ids").split() == ["100", "101", "102"], "3 containers expected")
    check("RUNNER_LABELS=docker\\,ci" in read(f"{STATE}/ct-100-bootstrap") or "RUNNER_LABELS=docker,ci" in read(f"{STATE}/ct-100-bootstrap"), "labels")
    check("--cores\n1" in read(f"{STATE}/ct-101.create") and "--memory\n3072" in read(f"{STATE}/ct-101.create"), "small size per CT")
    assert_no_secret_leak()


def case_local_checkout_is_copied():
    reset_host()
    child = pexpect.spawn("bash", [f"{ROOT}/install.sh"], cwd="/tmp", env=env(), dimensions=(40, 120),
                          encoding="utf-8", codec_errors="replace", timeout=60)
    child.logfile_read = Capture()
    drive(child, wizard(), until=r"are online")
    check(finish(child) == 0, "exit")
    check("git clone" not in calls() and "Deployed scripts from /src" in transcript(child), "local checkout not used")


CASES = [v for k, v in sorted(globals().items()) if k.startswith("case_")]

if __name__ == "__main__":
    only = sys.argv[1:]
    for fn in CASES:
        name = fn.__name__[5:]
        if only and name not in only:
            continue
        run_case(name, fn)
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} e2e cases passed")
    sys.exit(1 if failed else 0)
