#!/usr/bin/env bash
# scripts/12_install_teamviewer.sh — install TeamViewer (full client) at a pinned version.
#
# Version, download URL, and SHA-256 are pinned in lib/versions.sh; that file
# documents why the dl.teamviewer.com URL pattern is what's pinnable.
#
# We install the FULL client (teamviewer_amd64.deb), NOT the host-only package
# (teamviewer-host_amd64.deb). The .deb declares 'Conflicts: teamviewer-host'
# so the two cannot coexist. The full client supports both incoming and
# outgoing connections.
#
# After install, teamviewerd is enabled and listens on 127.0.0.1:5939 only.
# TeamViewer reaches its cloud relay infrastructure via OUTBOUND connections
# only; no inbound exposure is required or desired. The script verifies the
# listener is on 127.0.0.1 and aborts loud if it ever appears on 0.0.0.0.
#
# Usage:
#   sudo bash scripts/12_install_teamviewer.sh
#
# Manual GUI steps after this script (cannot be automated):
#   1. Launch TeamViewer from the Activities menu.
#   2. Accept the EULA.
#   3. Extras -> Options -> General -> check "Start TeamViewer with system".
#      Prompts once for sudo. The .deb postinst already enables
#      teamviewerd.service for boot, but that alone is NOT sufficient — without
#      this in-app toggle, remote connections fail after a reboot even though
#      `systemctl is-enabled teamviewerd` reports `enabled`.
#   4. Sign in to your TeamViewer account in the main window and grant Easy
#      Access to this device. Easy Access binds the device to the account so
#      it appears in your account's device list under its hostname — any
#      TeamViewer client signed into the same account connects by clicking
#      that entry, with no per-device password and no TeamViewer ID to type.

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

# Save under teamviewer_amd64.deb (matches the canonical filename) so that
# 'apt install ./teamviewer_amd64.deb' works the same as if downloaded from
# the non-versioned URL.
DEB="$DOWNLOAD_DIR/teamviewer_amd64.deb"

section "downloading TeamViewer $TEAMVIEWER_VERSION"
info "URL:    $TEAMVIEWER_DEB_URL"
info "target: $DEB"
sudo -u "$TARGET_USER" curl -fL --output "$DEB" "$TEAMVIEWER_DEB_URL"
[ -s "$DEB" ] || die "downloaded file is empty: $DEB"
ls -la "$DEB"

section "verifying SHA-256"
verify_sha256 "$DEB" "$TEAMVIEWER_DEB_SHA256"

section "verifying it is a valid Debian package"
PKG_NAME="$(dpkg-deb --field "$DEB" Package)"
PKG_VERSION="$(dpkg-deb --field "$DEB" Version)"
[ "$PKG_NAME" = "teamviewer" ] \
    || die "expected Package=teamviewer in the .deb, got '$PKG_NAME' (wrong asset?)"
[ "$PKG_VERSION" = "$TEAMVIEWER_VERSION" ] \
    || die "expected Version=$TEAMVIEWER_VERSION in the .deb, got '$PKG_VERSION'"
info "Debian package metadata matches pin: $PKG_NAME = $PKG_VERSION"

section "installing via apt"
apt-get install -y "$DEB"

section "verification"

state="$(dpkg -l teamviewer 2>/dev/null | awk '/^.. +teamviewer / {print $1; exit}')"
[ "$state" = "ii" ] || die "teamviewer package is not in installed state (got '$state')"
installed_version="$(dpkg -s teamviewer | awk '/^Version:/ {print $2}')"
[ "$installed_version" = "$TEAMVIEWER_VERSION" ] \
    || die "installed version $installed_version does not match pin $TEAMVIEWER_VERSION"
dpkg -l teamviewer | awk '/^ii/{print $1, $2, $3}'

require_command teamviewer
require_systemd_active teamviewerd.service

# Confirm 5939 is bound to 127.0.0.1 ONLY. On a DMZ host, a 0.0.0.0:5939
# listener would be a serious finding.
if ss -tln | grep -qE '^.* +127\.0\.0\.1:5939 '; then
    info "teamviewerd is listening on 127.0.0.1:5939 — correct"
elif ss -tln | grep -qE ':5939\b'; then
    die "FATAL: teamviewerd is listening on 5939 but not on 127.0.0.1 — exposure risk"
else
    warn "5939 not yet listening (daemon may still be initializing). Re-check with: ss -tln | grep :5939"
fi

section "success — install complete"
cat <<'MANUAL'
Manual GUI steps (cannot be automated):

  1. Launch TeamViewer from the Activities menu.
  2. Accept the EULA.
  3. Extras -> Options -> General -> check "Start TeamViewer with system."
     TeamViewer prompts once for your sudo password. The .deb postinst
     already enables teamviewerd.service for boot, but THAT ALONE IS NOT
     ENOUGH — without this in-app toggle, remote connections fail after a
     reboot even though `systemctl is-enabled teamviewerd` reports `enabled`.
  4. Sign in to your TeamViewer account in the main window and grant Easy
     Access to this device. Easy Access binds the device to the account so
     it appears in your account's device list under its hostname — any
     TeamViewer client signed into the same account connects by clicking
     that entry, with no per-device password and no TeamViewer ID to type.
MANUAL
