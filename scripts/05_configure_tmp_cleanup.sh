#!/usr/bin/env bash
# scripts/05_configure_tmp_cleanup.sh — relax the systemd /tmp cleanup policy.
#
# Default Ubuntu behavior, from /usr/lib/tmpfiles.d/tmp.conf:
#   D /tmp 1777 root root 30d
#
# - Capital "D" tells systemd-tmpfiles to PURGE /tmp on every boot via
#   systemd-tmpfiles-setup.service --remove. This is too aggressive for a
#   workstation that keeps cloned repos, build artifacts, or reference data
#   under /tmp.
# - "30d" tells the periodic systemd-tmpfiles-clean.timer to delete files
#   that have not been touched for 30+ days.
#
# This script writes /etc/tmpfiles.d/tmp.conf (which overrides the system
# default in /usr/lib/) with:
#   - lowercase "d" — keep /tmp contents across reboots
#   - 90d           — periodic cleanup deletes only files older than 90 days
#
# Effective on next reboot (for the non-purge change) and on the next
# tmpfiles-clean cycle (for the 90-day window).
#
# Usage:
#   sudo bash scripts/05_configure_tmp_cleanup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root

OVERRIDE=/etc/tmpfiles.d/tmp.conf
SYSTEM_DEFAULT=/usr/lib/tmpfiles.d/tmp.conf
DESIRED_LINE='d /tmp 1777 root root 90d'

[ -f "$SYSTEM_DEFAULT" ] || die "$SYSTEM_DEFAULT missing — is systemd-tmpfiles installed?"

# Idempotency: if the override already contains the exact desired line, no-op.
if [ -f "$OVERRIDE" ] && grep -qF -- "$DESIRED_LINE" "$OVERRIDE"; then
    info "$OVERRIDE already configured — nothing to do"
    exit 0
fi

cat >"$OVERRIDE" <<EOF
# Override of /usr/lib/tmpfiles.d/tmp.conf
#   - lowercase "d": do not remove /tmp contents on reboot (--remove no-op)
#   - 90d:           periodic cleanup (--clean) deletes files older than 90 days
$DESIRED_LINE
EOF

# Post-condition.
grep -qF -- "$DESIRED_LINE" "$OVERRIDE" \
    || die "$OVERRIDE write verification failed (expected line not found)"

info "wrote $OVERRIDE:"
cat "$OVERRIDE"

section "success"
info "non-purge behavior: effective on next reboot."
info "90-day cleanup window: effective on next systemd-tmpfiles-clean cycle (daily by default)."
