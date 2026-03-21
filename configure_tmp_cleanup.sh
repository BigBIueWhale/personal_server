#!/usr/bin/env bash
# configure_tmp_cleanup.sh — Override systemd /tmp cleanup policy
#
# Default Ubuntu behavior (from /usr/lib/tmpfiles.d/tmp.conf):
#   D /tmp 1777 root root 30d
#
# The uppercase "D" directive tells systemd-tmpfiles to purge /tmp contents
# when run with --remove (which happens at every boot via
# systemd-tmpfiles-setup.service). Files older than 30 days are also
# deleted periodically by the systemd-tmpfiles-clean.timer.
#
# This script creates /etc/tmpfiles.d/tmp.conf which overrides the
# system default:
#   - Lowercase "d" — stop purging /tmp on reboot
#   - 90d — periodic cleanup only deletes files older than 90 days
#
# The periodic cleanup timer (systemd-tmpfiles-clean.timer) still runs;
# only the age threshold and boot-time removal behavior change.

set -euo pipefail

OVERRIDE="/etc/tmpfiles.d/tmp.conf"
SYSTEM_DEFAULT="/usr/lib/tmpfiles.d/tmp.conf"

echo "=== Configure /tmp cleanup ==="
echo ""

if [[ -f "$OVERRIDE" ]]; then
    echo "Override already exists at $OVERRIDE:"
    cat "$OVERRIDE"
    echo ""
    read -rp "Overwrite? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo "Current system default ($SYSTEM_DEFAULT):"
grep -v '^#' "$SYSTEM_DEFAULT" | grep -v '^$' || echo "  (not found)"
echo ""

sudo tee "$OVERRIDE" > /dev/null <<'EOF'
# Override /usr/lib/tmpfiles.d/tmp.conf
# Lowercase "d" — do not remove /tmp contents on reboot (--remove)
# 90d — periodic cleanup (--clean) deletes files older than 90 days
d /tmp 1777 root root 90d
EOF

echo "Written $OVERRIDE:"
cat "$OVERRIDE"
echo ""
echo "Done. Changes take effect on next reboot / next tmpfiles-clean cycle."
