#!/usr/bin/env bash
# scripts/03_configure_gdm_xorg.sh — force GDM's greeter (login screen) to use Xorg.
#
# Even after the gdm3 noble-updates patch forces Xorg as the default user
# session on NVIDIA hardware (see README §0), the GDM greeter — the login
# screen itself, before any user logs in — defaults to Wayland. RustDesk warns
# about this on launch: during the brief greeter window after each reboot,
# RustDesk has no X server to attach to and cannot capture the screen. If
# autologin ever fails for any reason, you are locked out remotely until
# someone touches the keyboard.
#
# This script uncomments the WaylandEnable=false line in /etc/gdm3/custom.conf,
# which tells GDM to use Xorg for the greeter as well. Effective on next reboot.
#
# Usage:
#   sudo bash scripts/03_configure_gdm_xorg.sh
#
# Side effects:
#   - Backs up /etc/gdm3/custom.conf to /etc/gdm3/custom.conf.bak-<timestamp>.
#   - Edits /etc/gdm3/custom.conf in place (one line: '#WaylandEnable=false' -> 'WaylandEnable=false').
#   - Does NOT restart gdm3. That would terminate the active session, including
#     any running Claude/SSH/RustDesk session you have open. Effective on next reboot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root

CONF=/etc/gdm3/custom.conf
[ -f "$CONF" ] || die "$CONF not found — is gdm3 installed?"

# Idempotency: if the line is already uncommented, no-op.
if grep -qE '^WaylandEnable=false[[:space:]]*$' "$CONF"; then
    info "WaylandEnable=false is already active in $CONF — nothing to do"
    exit 0
fi

# We require the canonical commented form to be present. If neither the
# commented form nor the active form is there, the file has been modified in
# some unexpected way and we refuse to guess.
if ! grep -qE '^#WaylandEnable=false[[:space:]]*$' "$CONF"; then
    die "neither '#WaylandEnable=false' nor 'WaylandEnable=false' found in $CONF — refuse to guess"
fi

TS="$(date +%Y%m%d-%H%M%S)"
BAK="$CONF.bak-$TS"
cp "$CONF" "$BAK"
info "backup written: $BAK"

sed -i 's/^#WaylandEnable=false$/WaylandEnable=false/' "$CONF"

# Post-condition: confirm the active line is now present.
grep -qE '^WaylandEnable=false[[:space:]]*$' "$CONF" \
    || die "edit failed: WaylandEnable=false is not present after sed (see $BAK for the original)"

section "diff"
diff "$BAK" "$CONF" || true   # diff returns 1 on differences, which is the normal case here

section "success"
info "change takes effect on NEXT REBOOT."
warn "do NOT restart gdm3 right now — that would terminate your active session."
