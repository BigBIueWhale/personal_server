#!/usr/bin/env bash
# scripts/12_disable_ipv6.sh — disable IPv6 on this box.
#
# This box is reachable from the internet on its static IPv4 through the router's
# DMZ; its globally-routable IPv6 addresses would be a second, un-NAT'd front
# door that nothing here needs. Turn IPv6 off at the kernel so there is no v6
# surface to reason about. sshd is pinned IPv4-only in scripts/05, so this
# disables no listening service.
#
# Run this before the static IP (scripts/13). Idempotent: a re-run rewrites the
# same sysctl drop-in and re-asserts the same state.
#
# Usage:
#   sudo bash scripts/12_disable_ipv6.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu_noble

# If SSH is installed but still bound to IPv6, disabling IPv6 now can leave
# ssh.socket unable to bind on the next reboot (scripts/05 pins it to IPv4).
# Warn rather than fail: the running listener is unaffected; the risk is reboot.
if dpkg -s openssh-server >/dev/null 2>&1 && ss -tln | grep -qE '\[::\]:22'; then
    warn "ssh.socket is still listening on [::]:22 — run scripts/05 to pin SSH to IPv4 first, or it may fail to bind on reboot with IPv6 off"
fi

section "disable IPv6"

SYSCTL_CONF=/etc/sysctl.d/99-disable-ipv6.conf
read -r -d '' SYSCTL_CONTENT <<'EOF' || true
# Managed by 12_disable_ipv6.sh — this box is IPv4-only on the public side. Its
# public path is the static IPv4 via the router DMZ; globally-routable IPv6
# would be an un-NAT'd second ingress that nothing here needs.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

if [ -f "$SYSCTL_CONF" ] && printf '%s\n' "$SYSCTL_CONTENT" | cmp -s - "$SYSCTL_CONF"; then
    info "$SYSCTL_CONF already current"
else
    printf '%s\n' "$SYSCTL_CONTENT" > "$SYSCTL_CONF"
    info "wrote $SYSCTL_CONF"
fi
sysctl -p "$SYSCTL_CONF" >/dev/null

[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ] \
    || die "net.ipv6.conf.all.disable_ipv6 did not take"
if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
    die "global IPv6 addresses still present after disable — investigate"
fi
info "IPv6 disabled at the kernel; no global v6 addresses remain"

section "success"
