#!/usr/bin/env bash
# scripts/08_install_docker.sh — install Docker CE from Docker's official repository.
#
# Why docker-ce (and not docker.io from Ubuntu's universe):
#   - The NVIDIA Container Toolkit (next script) is officially tested and
#     supported against docker-ce.
#   - The Compose plugin, Buildx plugin, and security advisories track docker-ce.
#   - Ubuntu's docker.io lags upstream.
#
# Sequence:
#   (a) Prove the running Ubuntu kernel contains the corrected Bad Epoll fix and
#       refuse any installed Docker component newer than this repo's exact pin.
#   (b) Remove any conflicting/older Docker packages (no-ops on a clean box).
#   (c) Install ca-certificates + curl, fetch Docker's GPG key under
#       /etc/apt/keyrings/docker.asc.
#   (d) Write /etc/apt/sources.list.d/docker.sources in Deb822 format. (Modern
#       preferred over the legacy one-line 'deb [...]' format.)
#   (e) apt update.
#   (f) apt install docker-ce, docker-ce-cli, containerd.io,
#       docker-buildx-plugin, docker-compose-plugin.
#   (g) Add the invoking user to the 'docker' group, enable+start docker.service
#       and containerd.service.
#   (h) Smoke test: docker run --rm hello-world (using sudo, because the group
#       change is not effective in the current shell).
#   (i) Sanity checks: docker version, no TCP socket, DOCKER-USER chain present.
#
# Operational rule for this DMZ host (DOCKER-USER chain bypasses INPUT) and
# the docker-group-is-root-equivalent caveat are covered in README §11. The
# script enforces the no-TCP-socket part of that posture in step (i).
#
# Usage:
#   sudo bash scripts/08_install_docker.sh
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
require_command dpkg
require_command dpkg-query
require_command sort
require_command uname
require_sudo_user

TARGET_USER="$SUDO_USER"

# Print the fixed Ubuntu package-version floor for a supported running generic
# kernel. Ubuntu backported the corrected CVE-2026-46242 fix to these older
# kernel tracks; upstream generic kernels from 7.1 onward contain it directly.
bad_epoll_fixed_floor() {
    local kernel_release="$1"
    local base_version="${kernel_release%%-*}"

    case "$kernel_release" in
        6.8.*-generic)  printf '%s' '6.8.0-137.137'; return 0 ;;
        6.17.*-generic) printf '%s' '6.17.0-42.42'; return 0 ;;
        7.0.*-generic)  printf '%s' '7.0.0-28.28~24.04.1'; return 0 ;;
        *-generic)
            if dpkg --compare-versions "$base_version" ge '7.1'; then
                printf '%s' 'upstream-7.1'
                return 0
            fi
            ;;
    esac
    return 1
}

kernel_package_version() {
    local kernel_release="$1"
    dpkg-query -W -f='${Version}' "linux-image-${kernel_release}" 2>/dev/null
}

kernel_has_bad_epoll_fix() {
    local kernel_release="$1"
    local package_version="$2"
    local fixed_floor

    fixed_floor="$(bad_epoll_fixed_floor "$kernel_release")" || return 1
    if [ "$fixed_floor" = 'upstream-7.1' ]; then
        return 0
    fi
    dpkg --compare-versions "$package_version" ge "$fixed_floor"
}

newest_installed_generic_kernel() {
    local records
    records="$(
        dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Abbrev}\n' \
            'linux-image-[0-9]*-generic' 2>/dev/null || true
    )"
    printf '%s\n' "$records" \
        | awk -F '\t' '$3 ~ /^ii/ {sub(/^linux-image-/, "", $1); print $1}' \
        | sort -V \
        | tail -n 1
}

require_bad_epoll_fixed_running_kernel() {
    local running_release running_version fixed_floor newest_release newest_version
    running_release="$(uname -r)"
    running_version="$(kernel_package_version "$running_release")" || \
        die "cannot map the running kernel '$running_release' to an installed linux-image package"
    [ -n "$running_version" ] || \
        die "the installed package version for the running kernel '$running_release' is empty"

    newest_release="$(newest_installed_generic_kernel)"
    if [ -e /var/run/reboot-required ] \
        && [ -n "$newest_release" ] \
        && [ "$newest_release" != "$running_release" ]; then
        newest_version="$(kernel_package_version "$newest_release")" || true
        if [ -n "$newest_version" ] \
            && kernel_has_bad_epoll_fix "$newest_release" "$newest_version"; then
            die "fixed kernel $newest_release ($newest_version) is installed but $running_release is still running; reboot before installing Docker"
        fi
    fi

    fixed_floor="$(bad_epoll_fixed_floor "$running_release")" || \
        die "running kernel '$running_release' is not a supported Bad-Epoll-fixed Ubuntu 24.04 generic track; install current linux-generic or linux-generic-hwe-24.04 updates and reboot"
    if ! kernel_has_bad_epoll_fix "$running_release" "$running_version"; then
        die "running kernel $running_release comes from vulnerable package $running_version; this track requires $fixed_floor or newer for CVE-2026-46242. Apply Ubuntu kernel updates and reboot first"
    fi
    info "running kernel $running_release ($running_version) contains the corrected CVE-2026-46242 fix"
}

refuse_newer_installed_package() {
    local package="$1"
    local pinned_version="$2"
    local record status installed_version

    record="$(dpkg-query -W -f='${Status}\t${Version}' "$package" 2>/dev/null || true)"
    [ -n "$record" ] || return 0
    status="${record%%$'\t'*}"
    installed_version="${record#*$'\t'}"
    [ "$status" = 'install ok installed' ] || return 0

    if dpkg --compare-versions "$installed_version" gt "$pinned_version"; then
        die "repository pin is stale: installed $package $installed_version is newer than pinned $pinned_version; refusing an implicit downgrade. Update and validate scripts/lib/versions.sh first"
    fi
}

section "(a) security and exact-version preflight"
require_bad_epoll_fixed_running_kernel
refuse_newer_installed_package docker-ce "$DOCKER_CE_VERSION"
refuse_newer_installed_package docker-ce-cli "$DOCKER_CE_CLI_VERSION"
refuse_newer_installed_package containerd.io "$CONTAINERD_IO_VERSION"
refuse_newer_installed_package docker-buildx-plugin "$DOCKER_BUILDX_PLUGIN_VERSION"
refuse_newer_installed_package docker-compose-plugin "$DOCKER_COMPOSE_PLUGIN_VERSION"
info "no installed Docker component is newer than the repository's tested pins"

section "(b) remove conflicting/older Docker packages (no-ops on a clean box)"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>&1 | grep -E "Removing|not installed|0 newly installed" || true
done

section "(c) install ca-certificates + curl, add Docker GPG key"
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

section "(d) write /etc/apt/sources.list.d/docker.sources (Deb822 format)"
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

section "(e) apt update"
apt-get update

section "(f) install docker-ce + plugins (pinned versions from lib/versions.sh)"
apt-get install -y \
    "docker-ce=$DOCKER_CE_VERSION" \
    "docker-ce-cli=$DOCKER_CE_CLI_VERSION" \
    "containerd.io=$CONTAINERD_IO_VERSION" \
    "docker-buildx-plugin=$DOCKER_BUILDX_PLUGIN_VERSION" \
    "docker-compose-plugin=$DOCKER_COMPOSE_PLUGIN_VERSION"

section "(g) post-install: add $TARGET_USER to 'docker' group, enable services"
# The docker-ce postinst creates the 'docker' group; we just add the user.
usermod -aG docker "$TARGET_USER"
systemctl enable --now docker.service containerd.service

require_systemd_active docker.service
require_systemd_active containerd.service

section "(h) smoke test: docker run --rm hello-world"
# Use root explicitly (we are root). The user's group change is not effective
# in this shell yet, and we want this script to succeed without re-login.
docker run --rm hello-world

section "(i) sanity checks"

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
