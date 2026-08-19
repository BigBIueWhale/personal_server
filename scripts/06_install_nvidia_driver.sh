#!/usr/bin/env bash
# scripts/06_install_nvidia_driver.sh — install the NVIDIA driver, its prebuilt
# signed kernel module, and the userspace utils.
#
# This installs the proprietary NVIDIA driver in its 'open' kernel-module
# variant. The kernel module itself comes from Canonical's prebuilt, signed
# linux-modules-nvidia-<branch>-open-generic-hwe-24.04 package: Canonical builds
# and signs it against each HWE kernel ABI and ships it through noble-updates, so
# it loads under Secure Boot with no local signing key and follows the HWE kernel
# automatically on every kernel upgrade (the metapackage pulls the matching
# per-kernel linux-modules-nvidia-<branch>-open-<kver> alongside each new kernel).
#
# Naming that module package explicitly on the install line is load-bearing: it
# makes apt satisfy nvidia-driver-<branch>-open's module-provider dependency with
# the prebuilt module instead of pulling a second, source-built provider for the
# same /lib/modules/.../nvidia*.ko files.
#
# Driver branch: 595 by default. The RTX 5090 (Blackwell, compute capability
# 12.0) requires branch 555 or newer. The branch is overridable via the
# DRIVER_BRANCH environment variable in case Canonical ships a newer one in
# noble multiverse-updates by the time you run this. NVIDIA is pinned to a
# branch, not a frozen point version — the signed module is coupled to the
# kernel, so the whole 595 stack tracks noble-updates together (see
# scripts/lib/versions.sh).
#
# Note: if Ubuntu was installed with "Install third-party software" checked, the
# driver and this prebuilt module are likely already present. In that case this
# script is mostly a no-op for the driver, still asserts the pinned branch is in
# place, and adds the explicit utils package so nvidia-smi is reliably on PATH.
#
# Usage:
#   sudo bash scripts/06_install_nvidia_driver.sh
#   sudo DRIVER_BRANCH=600 bash scripts/06_install_nvidia_driver.sh   # override

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions

require_root
require_ubuntu_noble

# The branch is the unit of pinning for NVIDIA (see the header and versions.sh).
# The point release floats with the HWE kernel via the prebuilt signed module, so
# no per-package =version pins are applied here.
DRIVER_BRANCH="${DRIVER_BRANCH:-$NVIDIA_DRIVER_BRANCH}"
DRIVER_PKG="nvidia-driver-${DRIVER_BRANCH}-open"
MODULES_PKG="linux-modules-nvidia-${DRIVER_BRANCH}-open-generic-hwe-24.04"
UTILS_PKG="nvidia-utils-${DRIVER_BRANCH}"

if [ "$DRIVER_BRANCH" != "$NVIDIA_DRIVER_BRANCH" ]; then
    warn "DRIVER_BRANCH=$DRIVER_BRANCH overrides the pinned branch ($NVIDIA_DRIVER_BRANCH)"
fi
info "installing NVIDIA branch $DRIVER_BRANCH (latest point release in noble-updates)"

# Validate each package is offered by an apt source before installing. apt-cache
# returns 0 even on miss, so we check the Candidate field.
for pkg in "$DRIVER_PKG" "$MODULES_PKG" "$UTILS_PKG"; do
    cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
        die "package '$pkg' is not available from any configured apt source"
    fi
done

# Enforce a single kernel-module provider. If the source-built DKMS package is
# installed (a prior setup added it, or the OS installer selected it), remove it:
# it fights the prebuilt signed module for the same /lib/modules/.../nvidia*.ko
# and is what wedges dpkg on a driver or kernel bump. Removing it also clears any
# half-configured state that conflict already caused. No-op when it is absent.
if dpkg -s "nvidia-dkms-${DRIVER_BRANCH}-open" >/dev/null 2>&1; then
    warn "nvidia-dkms-${DRIVER_BRANCH}-open is installed; removing it so the prebuilt signed module is the sole provider"
    apt-get remove -y "nvidia-dkms-${DRIVER_BRANCH}-open"
    dpkg --configure -a
fi

section "apt update"
apt-get update

# $MODULES_PKG is listed explicitly on purpose: it satisfies the driver's
# module-provider dependency with the prebuilt signed module, so apt does not
# pull a second, source-built provider for the same kernel-module files.
section "apt install $DRIVER_PKG $MODULES_PKG $UTILS_PKG"
apt-get install -y "$DRIVER_PKG" "$MODULES_PKG" "$UTILS_PKG"

section "verification"

require_command nvidia-smi
info "running nvidia-smi:"
nvidia-smi

# Confirm the kernel module wired in for the running kernel is the packaged,
# prebuilt signed one — i.e. its file on disk is owned by a linux-modules-nvidia
# package matched to this kernel, not an unmanaged build.
KO="$(modinfo -F filename nvidia 2>/dev/null || true)"
[ -n "$KO" ] || die "modinfo could not locate an nvidia kernel module for kernel $(uname -r)"
OWNER="$(dpkg -S "$KO" 2>/dev/null | cut -d: -f1 || true)"
case "$OWNER" in
    linux-modules-nvidia-${DRIVER_BRANCH}-open-*)
        info "kernel module: $KO"
        info "provided by:   $OWNER"
        ;;
    *)
        die "nvidia module '$KO' is not owned by a linux-modules-nvidia-${DRIVER_BRANCH}-open package (owner: ${OWNER:-unknown}) — the prebuilt signed module is not the active provider for $(uname -r)"
        ;;
esac

section "success"
info "driver branch $DRIVER_BRANCH installed; kernel module tracks the HWE kernel."
