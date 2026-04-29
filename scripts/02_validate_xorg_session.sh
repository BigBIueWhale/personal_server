#!/usr/bin/env bash
# scripts/02_validate_xorg_session.sh — assert the current login session is Xorg, not Wayland.
#
# This repo only supports Xorg sessions. See README §0 for the reasoning. This
# script is a fast, dependency-free check you can (and should) run after every
# fresh login, before doing anything else, to confirm you are in the right
# environment.
#
# Usage:
#   bash scripts/02_validate_xorg_session.sh
#
# Side effects: none. The script reads $XDG_SESSION_TYPE and exits 0 if it is
# "x11", non-zero otherwise. No files are modified.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# Run as the desktop user, not root. Root may have different XDG_SESSION_TYPE
# semantics depending on how it was reached (sudo -i vs sudo without -i etc.).
require_non_root

require_xorg_session
info "OK — XDG_SESSION_TYPE=$XDG_SESSION_TYPE"

# Belt and suspenders: also confirm there is no running mutter --wayland and
# no Xwayland process. Either would signal a Wayland session despite the env.
if pgrep -af 'mutter.*--wayland' >/dev/null 2>&1; then
    die "mutter --wayland is running — Wayland is active despite XDG_SESSION_TYPE"
fi
if pgrep -x Xwayland >/dev/null 2>&1; then
    die "Xwayland is running — the session is hybrid Wayland-with-X11-translation, not native Xorg"
fi
if ! pgrep -x Xorg >/dev/null 2>&1; then
    die "no Xorg process found — confirm 'ps -ef | grep Xorg' before continuing"
fi

info "Xorg process detected — session is genuinely X11."
