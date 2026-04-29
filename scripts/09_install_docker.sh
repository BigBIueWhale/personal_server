#!/usr/bin/env bash
# scripts/09_install_docker.sh — install Docker CE from Docker's official repository.
#
# Why docker-ce (and not docker.io from Ubuntu's universe):
#   - The NVIDIA Container Toolkit (next script) is officially tested and
#     supported against docker-ce.
#   - The Compose plugin, Buildx plugin, and security advisories track docker-ce.
#   - Ubuntu's docker.io lags upstream.
#
# Sequence:
#   (a) Remove any conflicting/older Docker packages (no-ops on a clean box).
#   (b) Install ca-certificates + curl, fetch Docker's GPG key under
#       /etc/apt/keyrings/docker.asc.
#   (c) Write /etc/apt/sources.list.d/docker.sources in Deb822 format. (Modern
#       preferred over the legacy one-line 'deb [...]' format.)
#   (d) apt update.
#   (e) apt install docker-ce, docker-ce-cli, containerd.io,
#       docker-buildx-plugin, docker-compose-plugin.
#   (f) Add the invoking user to the 'docker' group, enable+start docker.service
#       and containerd.service.
#   (g) Smoke test: docker run --rm hello-world (using sudo, because the group
#       change is not effective in the current shell).
#   (h) Sanity checks: docker version, no TCP socket, DOCKER-USER chain present.
#
# Operational rule for this DMZ host (DOCKER-USER chain bypasses INPUT) and
# the docker-group-is-root-equivalent caveat are covered in README §11. The
# script enforces the no-TCP-socket part of that posture in step (h).
#
# Usage:
#   sudo bash scripts/09_install_docker.sh
#
# After this script succeeds you must re-login (or run 'newgrp docker') for
# your user's docker-group membership to take effect in your shell.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions

require_root
require_ubuntu_noble
require_command curl
require_command apt-get
require_sudo_user

TARGET_USER="$SUDO_USER"

section "(a) remove conflicting/older Docker packages (no-ops on a clean box)"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>&1 | grep -E "Removing|not installed|0 newly installed" || true
done

section "(b) install ca-certificates + curl, add Docker GPG key"
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

section "(c) write /etc/apt/sources.list.d/docker.sources (Deb822 format)"
SUITE="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
ARCH="$(dpkg --print-architecture)"
[ -n "$SUITE" ] || die "could not determine UBUNTU_CODENAME / VERSION_CODENAME"
[ -n "$ARCH" ]  || die "could not determine architecture from dpkg"

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $SUITE
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
info "wrote /etc/apt/sources.list.d/docker.sources:"
cat /etc/apt/sources.list.d/docker.sources

section "(d) apt update"
apt-get update

section "(e) install docker-ce + plugins (pinned versions from lib/versions.sh)"
apt-get install -y \
    "docker-ce=$DOCKER_CE_VERSION" \
    "docker-ce-cli=$DOCKER_CE_CLI_VERSION" \
    "containerd.io=$CONTAINERD_IO_VERSION" \
    "docker-buildx-plugin=$DOCKER_BUILDX_PLUGIN_VERSION" \
    "docker-compose-plugin=$DOCKER_COMPOSE_PLUGIN_VERSION"

section "(f) post-install: add $TARGET_USER to 'docker' group, enable services"
# The docker-ce postinst creates the 'docker' group; we just add the user.
usermod -aG docker "$TARGET_USER"
systemctl enable --now docker.service containerd.service

require_systemd_active docker.service
require_systemd_active containerd.service

section "(g) smoke test: docker run --rm hello-world"
# Use root explicitly (we are root). The user's group change is not effective
# in this shell yet, and we want this script to succeed without re-login.
docker run --rm hello-world

section "(h) sanity checks"

info "docker version:"
docker version

info "verifying no TCP listener on 2375/2376 (Docker must be unix-socket only):"
if ss -tln | grep -qE ':(2375|2376)\b'; then
    die "FATAL: Docker is listening on a TCP socket — that is unexpected and a security risk on this DMZ host"
fi
info "no Docker TCP socket — correct"

info "DOCKER-USER chain (proves the daemon set up its iptables chains):"
iptables -L DOCKER-USER -n

section "success"
warn "you must re-login (or run 'newgrp docker') for the docker group membership"
warn "to take effect in your shell. Until then, prefix docker commands with sudo."
