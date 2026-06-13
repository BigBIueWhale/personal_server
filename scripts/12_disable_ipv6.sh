#!/usr/bin/env bash
# scripts/12_disable_ipv6.sh — disable IPv6 on this box, at the kernel.
#
# This box is reachable from the internet on its static IPv4 through the router's
# full DMZ; its globally-routable IPv6 addresses would be a second, un-NAT'd
# front door that nothing here needs. (With v6 up, TeamViewer will even hole-
# punch a direct v6 session over it.) The goal is NO v6 surface to reason about.
#
# Why this script uses the kernel boot parameter and not sysctl:
# the obvious approach — net.ipv6.conf.{all,default}.disable_ipv6=1 in a
# /etc/sysctl.d drop-in — does NOT disable IPv6 on this host, and earlier
# versions of this script shipped exactly that. 'default.disable_ipv6' only
# seeds interfaces brought up AFTER it is applied, but eno1 (a physical NIC) is
# registered in early boot before systemd-sysctl runs, so it keeps
# disable_ipv6=0 and the kernel autoconfigures it from router advertisements
# (accept_ra=1). The drop-in's one-shot check could even pass transiently (the
# 'all' write momentarily tears addresses down) and then SLAAC re-adds them —
# so it reported success while eno1 stayed fully v6-enabled. 'ipv6.disable=1'
# stops the v6 stack from initializing at all: no per-interface knob, no
# NetworkManager/netplan race, nothing left that can re-enable it.
#
# Because it is a boot parameter it takes effect on the NEXT boot. This script
# configures it, regenerates grub.cfg, and verifies the parameter is baked in;
# it then either validates the live result (if the running kernel already has
# it) or tells you a reboot is required. Re-run after rebooting to validate.
# Idempotent.
#
# sshd is pinned IPv4-only in scripts/05 (a ssh.socket drop-in that drops the
# packaged [::]:22 listener), so removing IPv6 disables no listening service.
# This script refuses to proceed if sshd is somehow still bound on IPv6, so a
# reboot cannot strand SSH and lock you out of this DMZ-exposed host.
#
# Run this before the static IP (scripts/13).
#
# Usage:
#   sudo bash scripts/12_disable_ipv6.sh
#   sudo reboot                            # required to activate
#   sudo bash scripts/12_disable_ipv6.sh   # re-run after reboot to validate
#
# Side effects:
#   - Adds 'ipv6.disable=1' to GRUB_CMDLINE_LINUX in /etc/default/grub.
#   - Regenerates /boot/grub/grub.cfg via update-grub.
#   - Removes /etc/sysctl.d/99-disable-ipv6.conf if present (the ineffective
#     drop-in written by earlier versions of this script).
#   - Changes nothing on the running kernel; the effect lands on the next boot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu_noble
require_command update-grub

KPARAM='ipv6.disable=1'
GRUB_DEFAULT=/etc/default/grub
GRUB_CFG=/boot/grub/grub.cfg
STALE_SYSCTL=/etc/sysctl.d/99-disable-ipv6.conf

# A GRUB_CMDLINE_LINUX="..." line that already carries exactly ipv6.disable=1 as a
# whole space-delimited token (so "ipv6.disable=10" does not register as present).
HAS_PARAM='^GRUB_CMDLINE_LINUX="([^"]*[[:space:]])?ipv6\.disable=1([[:space:]][^"]*)?"$'

# True once the box has actually booted with ipv6.disable=1 on its kernel cmdline.
running_kernel_v6_off() { grep -qE '(^| )ipv6\.disable=1( |$)' /proc/cmdline; }

# Idempotency: configured in /etc/default/grub AND baked into grub.cfg AND the
# stale drop-in is gone AND the running kernel already has no v6 stack -> done.
if running_kernel_v6_off \
   && grep -qE "$HAS_PARAM" "$GRUB_DEFAULT" 2>/dev/null \
   && grep -q 'ipv6\.disable=1' "$GRUB_CFG" 2>/dev/null \
   && [ ! -e "$STALE_SYSCTL" ] \
   && [ ! -e /proc/sys/net/ipv6 ]; then
    info "IPv6 already disabled at the kernel and validated live — nothing to do"
    exit 0
fi

# Safety gate: never strand SSH on the next boot.
if dpkg -s openssh-server >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE '\[::\]:22([^0-9]|$)'; then
    die "sshd is still bound on IPv6 ([::]:22). Disabling IPv6 at the kernel would break SSH on the next boot and could lock you out. Run scripts/05 (pins SSH to IPv4) first, then re-run this."
fi

section "set $KPARAM in $GRUB_DEFAULT"

[ -f "$GRUB_DEFAULT" ] || die "$GRUB_DEFAULT not found — unexpected on Ubuntu"

# Require exactly one well-formed, double-quoted GRUB_CMDLINE_LINUX line. Refuse
# to edit any other shape rather than guess at it.
n_lines="$(grep -cE '^GRUB_CMDLINE_LINUX="[^"]*"$' "$GRUB_DEFAULT" || true)"
[ "$n_lines" = "1" ] || die "expected exactly one GRUB_CMDLINE_LINUX=\"...\" line in $GRUB_DEFAULT, found $n_lines — refusing to edit blindly"

grub_changed=0
if grep -qE "$HAS_PARAM" "$GRUB_DEFAULT"; then
    info "$GRUB_DEFAULT already carries $KPARAM"
else
    # Insert the token inside the quotes, then trim a leading space if the value
    # was empty ("" -> "ipv6.disable=1", not " ipv6.disable=1"). Touches only
    # GRUB_CMDLINE_LINUX, never GRUB_CMDLINE_LINUX_DEFAULT.
    sed -ri 's/^(GRUB_CMDLINE_LINUX=")(.*)(")$/\1\2 ipv6.disable=1\3/' "$GRUB_DEFAULT"
    sed -ri 's/^(GRUB_CMDLINE_LINUX=")[[:space:]]+/\1/'                 "$GRUB_DEFAULT"
    grep -qE "$HAS_PARAM" "$GRUB_DEFAULT" || die "failed to set $KPARAM in $GRUB_DEFAULT"
    grub_changed=1
    info "added $KPARAM to GRUB_CMDLINE_LINUX"
fi

section "regenerate $GRUB_CFG"

if [ "$grub_changed" = 1 ] || ! grep -q 'ipv6\.disable=1' "$GRUB_CFG" 2>/dev/null; then
    update-grub || die "update-grub failed"
else
    info "$GRUB_CFG already carries $KPARAM — skipping regeneration"
fi
[ -f "$GRUB_CFG" ] || die "$GRUB_CFG missing after update-grub"
grep -q 'ipv6\.disable=1' "$GRUB_CFG" || die "$KPARAM did not propagate into $GRUB_CFG — refusing to claim success"
info "verified $KPARAM is baked into $GRUB_CFG"

section "remove superseded sysctl drop-in"

# Earlier versions wrote $STALE_SYSCTL with net.ipv6.conf.{all,default}.disable_ipv6=1.
# It never disabled IPv6 here, and under ipv6.disable=1 the net.ipv6.* keys do not
# exist — systemd-sysctl would log a failure for it at every boot. Remove it.
if [ -e "$STALE_SYSCTL" ]; then
    rm -f "$STALE_SYSCTL"
    [ ! -e "$STALE_SYSCTL" ] || die "could not remove $STALE_SYSCTL"
    info "removed $STALE_SYSCTL (ineffective; superseded by kernel $KPARAM)"
else
    info "no stale drop-in at $STALE_SYSCTL"
fi

section "validate"

if running_kernel_v6_off; then
    [ ! -e /proc/sys/net/ipv6 ] || die "running kernel has $KPARAM but /proc/sys/net/ipv6 exists — v6 stack unexpectedly present"
    if ip -6 addr show 2>/dev/null | grep -q 'inet6'; then
        die "IPv6 addresses still present despite $KPARAM — investigate"
    fi
    info "running kernel: no IPv6 stack and no inet6 addresses"
    section "success — IPv6 is disabled at the kernel and validated live"
else
    warn "configured and verified in $GRUB_CFG, but the running kernel still has IPv6 (this boot predates the change)."
    warn "activate it:    sudo reboot"
    warn "then validate:  sudo bash $0"
    section "configured — reboot required, then re-run to validate"
fi
