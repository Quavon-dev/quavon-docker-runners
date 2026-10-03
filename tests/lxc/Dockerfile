# Stand-in for the Proxmox LXC: Debian 13 with systemd as PID 1.
FROM debian:13
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl git gnupg procps iproute2 \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
