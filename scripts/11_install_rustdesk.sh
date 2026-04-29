#!/usr/bin/env bash
# scripts/11_install_rustdesk.sh — install RustDesk client at a pinned version.
#
# RustDesk is a self-hosted remote-desktop solution. We install the client (.deb)
# only — NOT the rendezvous/relay server pair (hbbs/hbbr), which is a separate
# Docker-deployed product. The client itself is "a server by default": once
# Direct IP Access is enabled in the GUI, the client process binds 21118/tcp
# and 21119/udp and accepts incoming P2P connections without any relay infra.
#
# Version, download URL, and SHA-256 are pinned in lib/versions.sh; that file
# documents why we use the deterministic GitHub release URL rather than the
# /releases/latest API.
#
# Install verb: 'apt install ./<deb>' rather than 'dpkg -i ./<deb>'. apt
# resolves Noble's t64 transitional package aliases (e.g., libgtk-3-0 ->
# libgtk-3-0t64) automatically; raw dpkg -i would fail with unmet deps. This
# is the canonical reference for that t64-aliases reasoning in this repo —
# other install scripts that use 'apt install ./<deb>' rely on the same.
#
# IMPORTANT architectural note about the .deb's systemd unit:
#   The .deb installs a system-wide rustdesk.service in
#   /usr/lib/systemd/system/rustdesk.service that runs `rustdesk --service`
#   as root. This unit is NOT a separate listener — it is a SUPERVISOR. It
#   internally invokes
#       sudo -E XDG_RUNTIME_DIR=/run/user/<uid> -u <user> \
#         /usr/share/rustdesk/rustdesk --server
#   to launch the actual P2P listener AS THE LOGGED-IN USER, with that user's
#   config in ~/.config/rustdesk/. There is therefore exactly ONE listener,
#   running as you, with your config. Do NOT disable rustdesk.service — it
#   is the supervisor that keeps your user-mode listener alive.
#
# Usage:
#   sudo bash scripts/11_install_rustdesk.sh
#
# Manual GUI steps after this script (cannot be automated):
#   1. Launch RustDesk from the Activities menu.
#   2. Settings -> Network -> enable "Direct IP Access".
#      (After this, port 21118/tcp starts listening; verify with:
#       ss -tln | grep :21118)
#   3. Settings -> Display -> uncheck "Hardware Codec" (saves ~500 MB VRAM
#      during sessions on this hardware).
#   4. Set a permanent password for unattended access.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions

require_root
require_ubuntu_noble
require_command curl
require_command sha256sum
require_sudo_user

TARGET_USER="$SUDO_USER"
TARGET_HOME="$(sudo_user_home)"
DOWNLOAD_DIR="$TARGET_HOME/Downloads"

sudo -u "$TARGET_USER" mkdir -p "$DOWNLOAD_DIR"

ASSET_NAME="rustdesk-${RUSTDESK_VERSION}-x86_64.deb"
DEB="$DOWNLOAD_DIR/$ASSET_NAME"

section "downloading RustDesk $RUSTDESK_VERSION"
info "URL:    $RUSTDESK_DEB_URL"
info "target: $DEB"
sudo -u "$TARGET_USER" curl -fL --output "$DEB" "$RUSTDESK_DEB_URL"
[ -s "$DEB" ] || die "downloaded file is empty: $DEB"
ls -la "$DEB"

section "verifying SHA-256"
verify_sha256 "$DEB" "$RUSTDESK_DEB_SHA256"

section "verifying it is a valid Debian package"
PKG_NAME="$(dpkg-deb --field "$DEB" Package)"
PKG_VERSION="$(dpkg-deb --field "$DEB" Version)"
[ "$PKG_NAME" = "rustdesk" ] \
    || die "expected Package=rustdesk in the .deb, got '$PKG_NAME'"
[ "$PKG_VERSION" = "$RUSTDESK_VERSION" ] \
    || die "expected Version=$RUSTDESK_VERSION in the .deb, got '$PKG_VERSION'"
info "Debian package metadata matches pin: $PKG_NAME = $PKG_VERSION"

section "installing via apt (resolves Noble's t64 transitional aliases)"
apt-get install -y "$DEB"

section "verification"

# Confirm the package is in the 'ii' (installed) state at the right version.
state="$(dpkg -l rustdesk 2>/dev/null | awk '/^.. rustdesk / {print $1; exit}')"
[ "$state" = "ii" ] || die "rustdesk package is not in installed state (got '$state')"
installed_version="$(dpkg -s rustdesk | awk '/^Version:/ {print $2}')"
[ "$installed_version" = "$RUSTDESK_VERSION" ] \
    || die "installed version $installed_version does not match pin $RUSTDESK_VERSION"
dpkg -l rustdesk | awk '/^ii/{print $1, $2, $3}'

require_command rustdesk

# The supervisor unit must be enabled (see header comment).
if ! systemctl is-enabled --quiet rustdesk.service; then
    die "rustdesk.service is not enabled — that is unusual; the .deb should have enabled it"
fi
info "rustdesk.service is enabled (it supervises the user-mode listener)"

section "success — install complete"
cat <<'MANUAL'
Manual GUI steps (cannot be automated):

  1. Launch RustDesk from the Activities menu.
  2. Settings -> Network -> enable "Direct IP Access".
     (After this, port 21118/tcp starts listening; verify with:
        ss -tln | grep :21118 )
  3. Settings -> Display -> uncheck "Hardware Codec".
     (Saves ~500 MB VRAM during active sessions on this hardware.)
  4. Set a permanent password for unattended access.
MANUAL
