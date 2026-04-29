#!/usr/bin/env bash
# scripts/06_install_openssh_server.sh — install and verify openssh-server.
#
# On Ubuntu 24.04, openssh-server is socket-activated:
#   - ssh.socket   listens on port 22 from boot. Enabled by default after install.
#   - ssh.service  is spawned by ssh.socket on each incoming connection. It
#                  shows as 'disabled / inactive' between connections; that is
#                  the correct steady state, not a misconfiguration.
#
# Therefore this script does NOT run 'systemctl enable ssh.service' (which would
# create a redundant unit linkage), and does NOT need the GNOME Settings ->
# Sharing -> Remote Login toggle (which is a no-op confirmation under the
# socket-activation model).
#
# This script does not change SSH authentication policy. /etc/ssh/sshd_config
# and any /etc/ssh/sshd_config.d/*.conf overrides are left alone.
#
# Usage:
#   sudo bash scripts/06_install_openssh_server.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu_noble

if dpkg -s openssh-server >/dev/null 2>&1; then
    info "openssh-server is already installed"
else
    section "apt update + install openssh-server"
    apt-get update
    apt-get install -y openssh-server
fi

section "verification"

# ssh.socket must be both enabled (starts at boot) and active (listening now).
if ! systemctl is-enabled --quiet ssh.socket; then
    die "ssh.socket is not enabled — it should be enabled by default after install"
fi
require_systemd_active ssh.socket
info "ssh.socket is enabled and active"

# Port 22 must be listening, on at least one interface.
if ! ss -tln | grep -qE ':22\b'; then
    die "port 22 is not listening after install"
fi
info "port 22 is listening:"
ss -tln | grep -E ':22\b'

section "success"
