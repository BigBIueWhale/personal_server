#!/usr/bin/env bash
# scripts/07_install_nvidia_driver.sh — install NVIDIA driver, DKMS, and userspace utils.
#
# This installs the proprietary NVIDIA driver in its 'open' kernel-module
# variant, plus the DKMS package (so the kernel module rebuilds automatically
# on every kernel upgrade), plus the userspace utilities (nvidia-smi etc.).
#
# Driver branch: 595 by default. The RTX 5090 (Blackwell, compute capability
# 12.0) requires branch 555 or newer. The branch is overridable via the
# DRIVER_BRANCH environment variable in case Canonical ships a newer one in
# noble multiverse-updates by the time you run this.
#
# Note: if Ubuntu was installed with "Install third-party software" checked,
# the driver is likely already installed. In that case this script is mostly a
# no-op for the driver itself but still adds DKMS (which the third-party
# checkbox does NOT install) and the explicit utils package, both of which
# matter for surviving kernel upgrades and having nvidia-smi reliably on PATH.
#
# Usage:
#   sudo bash scripts/07_install_nvidia_driver.sh
#   sudo DRIVER_BRANCH=600 bash scripts/07_install_nvidia_driver.sh   # override

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions

require_root
require_ubuntu_noble

# Branch is overridable via the env var; if overridden, the per-package version
# pins below are intentionally skipped because they only match the canonical
# 595 branch. The user opting into a different branch is opting out of pinning.
DRIVER_BRANCH="${DRIVER_BRANCH:-$NVIDIA_DRIVER_BRANCH}"
DRIVER_PKG="nvidia-driver-${DRIVER_BRANCH}-open"
DKMS_PKG="nvidia-dkms-${DRIVER_BRANCH}-open"
UTILS_PKG="nvidia-utils-${DRIVER_BRANCH}"

if [ "$DRIVER_BRANCH" = "$NVIDIA_DRIVER_BRANCH" ]; then
    DRIVER_SPEC="$DRIVER_PKG=$NVIDIA_DRIVER_VERSION"
    DKMS_SPEC="$DKMS_PKG=$NVIDIA_DKMS_VERSION"
    UTILS_SPEC="$UTILS_PKG=$NVIDIA_UTILS_VERSION"
    info "using pinned versions: $NVIDIA_DRIVER_VERSION"
else
    warn "DRIVER_BRANCH=$DRIVER_BRANCH overrides the pinned branch ($NVIDIA_DRIVER_BRANCH); installing latest available for $DRIVER_BRANCH"
    DRIVER_SPEC="$DRIVER_PKG"
    DKMS_SPEC="$DKMS_PKG"
    UTILS_SPEC="$UTILS_PKG"
fi

# Validate each package is offered by an apt source before installing. apt-cache
# returns 0 even on miss, so we check the Candidate field.
for pkg in "$DRIVER_PKG" "$DKMS_PKG" "$UTILS_PKG"; do
    cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
        die "package '$pkg' is not available from any configured apt source"
    fi
done

section "apt update"
apt-get update

section "apt install $DRIVER_SPEC $DKMS_SPEC $UTILS_SPEC"
apt-get install -y "$DRIVER_SPEC" "$DKMS_SPEC" "$UTILS_SPEC"

section "verification"

require_command nvidia-smi
info "running nvidia-smi:"
nvidia-smi

# DKMS must report at least one nvidia module. The exact format is:
#   nvidia/<version>, <kernel>, <arch>: installed
# (Possibly with trailing 'WARNING! Diff between built and installed module!'
# notes — these are harmless and explained in the README.)
if ! dkms status | grep -q '^nvidia/'; then
    die "no nvidia DKMS modules found in 'dkms status'"
fi
info "DKMS status:"
dkms status | grep '^nvidia/'

section "success"
info "driver branch $DRIVER_BRANCH installed."
info ""
info "If 'dkms status' shows 'Diff between built and installed module' notes, that"
info "indicates DKMS built the module fresh and the freshly-built bytes differ from"
info "the in-tree-built module currently loaded. Same version, different build"
info "artifact. Harmless — DKMS's build will be loaded on next reboot/kernel upgrade."
