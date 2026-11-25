#!/usr/bin/env bash
# GCE startup script for Debian 12. GCE runs it on every boot, so every step
# must be safe to repeat.
set -euo pipefail

AGENT_USER="agent"
AGENT_ID="1000" # must match `user: "1000:1000"` in agents/docker-compose.yml
METADATA_IP="169.254.169.254"

log() { echo "[startup] $*"; }

# --- 1 GB swap -------------------------------------------------------------
# Runs first: e2-micro has 1 GB RAM and apt can run out of memory without swap.
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  log "enabling swap"
  [ -f /swapfile ] || fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
fi
grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab

# --- remove exim4 ------------------------------------------------------------
# The Debian image ships a local mail daemon (~15 MB RSS) that nothing here uses;
# on a 1 GB VM that memory is better left free. A failure must not stop the steps below.
remove_exim4() {
  dpkg -s exim4-base >/dev/null 2>&1 || return 0
  log "removing exim4"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y exim4-base exim4-config 'exim4-daemon-*' || return 1
}

remove_exim4 || log "WARNING: exim4 removal failed"

# --- docker logging ----------------------------------------------------------
# Runs before the docker install so a fresh dockerd starts with this config
# instead of restarting to pick it up.
# Terraform sets docker-log-driver: gcplogs (Cloud Logging; needs enable_ops_roles,
# or containers fail to start) or local (rotating files on the VM only).
# Both cap local disk use: gcplogs keeps a dual-logging cache of 5 x 20 MB per container.
# non-blocking: when the driver can't keep up, drop log lines instead of stalling
# the container's stdout writes.
LOG_DRIVER=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' \
  "http://${METADATA_IP}/computeMetadata/v1/instance/attributes/docker-log-driver" || echo local)
install -d -m 0755 /etc/docker
cat >/etc/docker/daemon.json.new <<EOF
{
  "log-driver": "${LOG_DRIVER}",
  "log-opts": {"mode": "non-blocking", "max-buffer-size": "4m"}
}
EOF
if cmp -s /etc/docker/daemon.json.new /etc/docker/daemon.json; then
  rm /etc/docker/daemon.json.new
else
  log "docker log driver: ${LOG_DRIVER}"
  mv /etc/docker/daemon.json.new /etc/docker/daemon.json
  if systemctl is-active --quiet docker; then systemctl restart docker; fi
fi

# --- docker-ce + compose plugin (official repo) ------------------------------
# Follows https://docs.docker.com/engine/install/debian/ (deb822 sources file).
if ! dpkg -s docker-ce docker-compose-plugin >/dev/null 2>&1; then
  log "installing docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# --- block containers from the metadata server ------------------------------
# DOCKER-USER is jumped to from FORWARD, so this drops only traffic that
# containers route through the host. The host itself (and this script) can
# still reach the metadata server.
# The metadata IP is also the VM's DNS resolver (nameserver in /etc/resolv.conf,
# https://cloud.google.com/compute/docs/internal-dns), and Docker's embedded DNS
# forwards from inside the container's netns, so port 53 must stay open.
# Our rules are deleted and re-inserted so their order is always
# ACCEPT udp/53, ACCEPT tcp/53, DROP, ahead of anything else in the chain.
cat >/usr/local/sbin/docker-metadata-block.sh <<EOF
#!/bin/sh
set -eu
iptables -w -N DOCKER-USER 2>/dev/null || true
while iptables -w -D DOCKER-USER -d ${METADATA_IP}/32 -j DROP 2>/dev/null; do :; done
for proto in udp tcp; do
  while iptables -w -D DOCKER-USER -d ${METADATA_IP}/32 -p \$proto --dport 53 -j ACCEPT 2>/dev/null; do :; done
done
iptables -w -I DOCKER-USER 1 -d ${METADATA_IP}/32 -j DROP
iptables -w -I DOCKER-USER 1 -d ${METADATA_IP}/32 -p tcp --dport 53 -j ACCEPT
iptables -w -I DOCKER-USER 1 -d ${METADATA_IP}/32 -p udp --dport 53 -j ACCEPT
EOF
chmod 0755 /usr/local/sbin/docker-metadata-block.sh

# Before=docker.service: the rules exist before dockerd starts any container.
#   dockerd keeps an existing DOCKER-USER chain and its rules; it only adds the
#   FORWARD jump and a trailing RETURN.
# PartOf= + WantedBy=docker.service: `systemctl restart docker` restarts this
#   unit too, so the rules are reapplied every time docker starts or restarts.
cat >/etc/systemd/system/docker-metadata-block.service <<'EOF'
[Unit]
Description=Block Docker containers from the GCE metadata server
Before=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-metadata-block.sh

[Install]
WantedBy=docker.service
EOF
systemctl daemon-reload
systemctl enable docker-metadata-block.service >/dev/null
# On the first run docker is already up and the unit never ran, so run it now.
systemctl restart docker-metadata-block.service

# Docker stays installed but off: nothing runs in containers right now, and dockerd
# plus containerd cost memory on a 1 GB VM. docker.socket must go too, or the first
# `docker` call would socket-activate dockerd again. To use containers again, delete
# this line and run `systemctl enable --now docker.socket docker.service`.
systemctl disable --now docker.service docker.socket containerd.service >/dev/null 2>&1 || true

# --- Cloudflare WARP, proxy mode ---------------------------------------------
# PTT blocks GCP IPs. WARP in proxy mode listens on 127.0.0.1:40000 (SOCKS5) and
# only processes that are pointed at it use it; routing and SSH are untouched.
# Host loopback only: containers cannot reach it, and compose forbids host networking.
# A failure here must not stop the user setup below, so each step returns instead of
# relying on `set -e` (which is ignored inside an `if` condition).
WARP_CLI=(warp-cli --accept-tos)

install_warp() {
  if ! dpkg -s cloudflare-warp >/dev/null 2>&1; then
    log "installing cloudflare-warp"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get install -y ca-certificates curl gnupg || return 1
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg |
      gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg || return 1
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      >/etc/apt/sources.list.d/cloudflare-client.list || return 1
    apt-get update || return 1
    apt-get install -y cloudflare-warp || return 1
  fi
  systemctl enable --now warp-svc >/dev/null || return 1

  local ready=0
  for _ in $(seq 15); do
    if "${WARP_CLI[@]}" status >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" = 1 ] || return 1

  if ! "${WARP_CLI[@]}" registration show >/dev/null 2>&1; then
    "${WARP_CLI[@]}" registration new || return 1
  fi
  "${WARP_CLI[@]}" mode proxy || return 1
  "${WARP_CLI[@]}" connect || return 1
}

install_warp || log "WARNING: cloudflare-warp setup failed; PTT will not be reachable"

# --- keyring for ptt-agent's agy login ----------------------------------------
# agy keeps its Google login in the Secret Service keyring over D-Bus, which a headless
# VM lacks. ptt-agent's deploy/with-keyring.sh runs it inside a private D-Bus session
# with an unlocked gnome-keyring. Only the packages are installed here.
install_keyring_packages() {
  if dpkg -s dbus gnome-keyring libsecret-1-0 >/dev/null 2>&1; then
    return 0
  fi
  log "installing keyring packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || return 1
  apt-get install -y dbus gnome-keyring libsecret-1-0 || return 1
}

install_keyring_packages || log "WARNING: keyring package install failed; agy login will not persist"

# --- non-root agent user -----------------------------------------------------
# Runs last: if it fails, docker and the metadata block are already in place.
# Not in the docker group: docker group membership is root-equivalent.
# Operators run compose with sudo after logging in through OS Login.
if ! getent group "$AGENT_USER" >/dev/null; then
  groupadd --gid "$AGENT_ID" "$AGENT_USER"
fi
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir /opt/agents --uid "$AGENT_ID" --gid "$AGENT_USER" --shell /bin/bash "$AGENT_USER"
fi
# groupadd/useradd fail if the id is taken; this also catches a pre-existing
# agent user with the wrong ids, which compose's hard-coded user would not match.
if [ "$(id -u "$AGENT_USER")" != "$AGENT_ID" ] || [ "$(getent group "$AGENT_USER" | cut -d: -f3)" != "$AGENT_ID" ]; then
  log "ERROR: $AGENT_USER must have uid/gid $AGENT_ID to match agents/docker-compose.yml"
  exit 1
fi
install -d -m 0750 -o "$AGENT_USER" -g "$AGENT_USER" /opt/agents
install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_USER" /opt/agents/secrets

log "done"
