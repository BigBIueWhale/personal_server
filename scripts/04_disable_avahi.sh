#!/usr/bin/env bash
# scripts/04_disable_avahi.sh — fully disable avahi-daemon (mDNS / Bonjour / Zeroconf).
#
# avahi-daemon advertises and discovers local-network services via multicast
# UDP 5353. Use cases: AirPrint discovery, '.local' hostnames, SMB/AFP/NFS
# desktop discovery. NONE of these are useful on a server intentionally
# exposed via DMZ to the public internet — they only widen the local LAN
# attack surface.
#
# Why this script over the obvious 'systemctl stop ... && systemctl mask ...':
# avahi-daemon ships TWO unit files: a service unit and a socket unit. The
# socket unit is socket-activated (it listens on UDP 5353 itself, and triggers
# the service unit on the first incoming packet). If you stop the service
# without first masking the socket, an mDNS packet arriving in the gap between
# stop and mask will re-trigger the daemon. That actually happens — observed
# during this project's setup. Mask first, then stop, then forcibly kill any
# lingering process that survived the race.
#
# Usage:
#   sudo bash scripts/04_disable_avahi.sh
#
# Side effects:
#   - Masks avahi-daemon.service and avahi-daemon.socket (creates symlinks
#     pointing at /dev/null in /etc/systemd/system/).
#   - Stops both units.
#   - Sends SIGTERM, then SIGKILL, to any avahi-daemon process that survives.
#   - Verifies port 5353 is no longer listening.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root

is_masked() {
    local unit="$1"
    [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = "masked" ]
}

# Idempotency: if both units are masked, no daemon is running, and 5353 is
# closed, there is nothing to do.
if is_masked avahi-daemon.service \
   && is_masked avahi-daemon.socket \
   && ! pgrep -x avahi-daemon >/dev/null 2>&1 \
   && ! ss -uln 2>/dev/null | grep -qE ':5353\b'; then
    info "avahi is already fully disabled — nothing to do"
    exit 0
fi

section "masking units (prevents future activation)"
systemctl mask avahi-daemon.service avahi-daemon.socket

section "stopping any active instance"
# Both units may already be stopped or may fail because they're masked; do not
# hard-fail on stop — the kill loop below is the safety net.
systemctl stop avahi-daemon.service avahi-daemon.socket 2>&1 || true

section "killing any remaining avahi-daemon process"
# A masked unit cannot be re-triggered, so this kill is final.
if pgrep -x avahi-daemon >/dev/null 2>&1; then
    pkill -TERM avahi-daemon 2>&1 || true
    sleep 1
fi
if pgrep -x avahi-daemon >/dev/null 2>&1; then
    pkill -KILL avahi-daemon 2>&1 || true
    sleep 1
fi

section "verification"

if pgrep -x avahi-daemon >/dev/null 2>&1; then
    die "avahi-daemon process still running after disable+kill"
fi
info "no avahi-daemon process"

if ss -uln 2>/dev/null | grep -qE ':5353\b'; then
    die "port 5353/udp still has a listener"
fi
info "port 5353/udp is closed"

is_masked avahi-daemon.service \
    || die "avahi-daemon.service is not masked"
is_masked avahi-daemon.socket \
    || die "avahi-daemon.socket is not masked"
info "both units are masked"

section "success — avahi is fully disabled"
