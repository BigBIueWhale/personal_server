#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for the personal_server setup scripts.
#
# Sourced by every top-level script under scripts/. Never executed directly.
#
# Conventions:
#   - All scripts source this file at the top, BEFORE doing any work.
#   - This file enables strict bash mode (set -Eeuo pipefail). Sourcing scripts
#     inherit that. Do not unset.
#   - Helpers fail loud (exit non-zero with a clear message) on precondition
#     violations. They never fail silently.

# Strict bash. Inherited by sourcing scripts.
set -Eeuo pipefail

# Path constants (computed from this file's location, robust to CWD changes).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$LIB_DIR")"
REPO_DIR="$(dirname "$SCRIPTS_DIR")"
export LIB_DIR SCRIPTS_DIR REPO_DIR

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Print a labelled section header.
section() {
    echo
    echo "======================================================================"
    echo "  $*"
    echo "======================================================================"
}

# Informational line.
info()  { echo "[info] $*"; }

# Warning to stderr (non-fatal).
warn()  { echo "[warn] $*" >&2; }

# Fatal error: print to stderr and exit non-zero.
die()   { echo "[fatal] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Precondition helpers
# ---------------------------------------------------------------------------

# Abort if the current shell is not running as root.
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "this script must be run as root (use: sudo bash $0)"
    fi
}

# Abort if running under sudo. Used by scripts that must be invoked as the
# desktop user (e.g., session-validation), not as root.
require_non_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        die "this script must NOT be run as root; run it as your normal user"
    fi
}

# Abort if SUDO_USER is unset. Scripts that are invoked via sudo but need to
# touch the calling user's files (~/.bashrc, ~/Downloads, etc.) call this so
# they can resolve TARGET_USER and TARGET_HOME without ambiguity.
require_sudo_user() {
    if [ -z "${SUDO_USER:-}" ]; then
        die "this script must be invoked via 'sudo' (we read \$SUDO_USER to find your home directory)"
    fi
}

# Abort if the named command is not on PATH.
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command '$cmd' not found on PATH"
    fi
}

# Abort if the named dpkg package is not installed.
require_package() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        die "required package '$pkg' is not installed"
    fi
}

# Abort if the named systemd unit is not in the 'active' state.
require_systemd_active() {
    local unit="$1"
    if ! systemctl is-active --quiet "$unit"; then
        die "required systemd unit '$unit' is not active"
    fi
}

# Abort unless the current login session is Xorg (X11). This repo only supports
# Xorg — see README §0.
require_xorg_session() {
    local session_type="${XDG_SESSION_TYPE:-unset}"
    if [ "$session_type" != "x11" ]; then
        die "this repo only supports Xorg sessions. Current XDG_SESSION_TYPE=$session_type. See README §0."
    fi
}

# Abort unless the host is Ubuntu 24.04 LTS (noble). Used by every script that
# pins versions or repository URLs to noble.
require_ubuntu_noble() {
    [ -f /etc/os-release ] || die "/etc/os-release missing — cannot identify distribution"
    # Use a subshell so we don't leak /etc/os-release variables into the caller.
    local id codename
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    [ "$id" = "ubuntu" ]      || die "expected Ubuntu, got ID='$id'"
    [ "$codename" = "noble" ] || die "expected Ubuntu noble (24.04), got VERSION_CODENAME='$codename'"
}

# Resolve the home directory of the user named by SUDO_USER. Echoes the path on
# stdout. Aborts if SUDO_USER is unset or the home directory does not exist.
sudo_user_home() {
    require_sudo_user
    local home
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -d "$home" ] || die "home directory of \$SUDO_USER ($SUDO_USER) -> '$home' does not exist"
    printf '%s' "$home"
}

# ---------------------------------------------------------------------------
# Integrity helpers
# ---------------------------------------------------------------------------

# Verify the SHA-256 of $1 matches the lowercase hex digest in $2. Aborts on
# mismatch. Used after every download whose pinned hash we know.
verify_sha256() {
    local file="$1"
    local expected="$2"
    [ -f "$file" ] || die "verify_sha256: file '$file' does not exist"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        die "SHA-256 mismatch for '$file': expected $expected, got $actual"
    fi
    info "SHA-256 verified: $file"
}

# Source the version pins. Every install script that consumes the pins should
# call this immediately after sourcing common.sh. Kept as a separate call (not
# auto-sourced from common.sh) so non-installing scripts — like the Xorg
# session validator — don't pay the cost.
load_versions() {
    . "$LIB_DIR/versions.sh"
}
