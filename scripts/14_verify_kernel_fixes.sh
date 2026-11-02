#!/usr/bin/env bash
# scripts/14_verify_kernel_fixes.sh — the kernel security gate.
#
# Proves from machine code that the running kernel, and the kernel GRUB boots next,
# contain the security fixes this host needs. A version number would only say what
# a package claims, and kernels can arrive by themselves through unattended-upgrades.
#
# Do not point the router's DMZ at a machine until this passes. Re-run it after any
# kernel update. See README section 20.
#
# Read-only, and safe to run at any time.
#
# Usage:
#   sudo bash scripts/14_verify_kernel_fixes.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

UPGRADE_REPOSITORY=https://github.com/BigBIueWhale/cve-2026-98432-kernel-upgrade

main() {
    require_root
    require_ubuntu_noble
    require_command python3
    require_command zstd
    section 'Kernel security gate'
    if python3 -I -B "$SCRIPT_DIR/lib/kernel_fix_check.py"; then
        info 'the running kernel and the next boot are fixed'
        return
    fi
    warn "Try the normal route first: sudo apt-get update && sudo apt-get install --only-upgrade linux-generic-hwe-24.04"
    warn "If that brings no fixed kernel, Ubuntu hasn't published one yet. Use the emergency upgrade:"
    warn "  $UPGRADE_REPOSITORY, kernel-upgrade/PROCEDURE.md"
    die 'this kernel is not safe to expose: see README section 20'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
