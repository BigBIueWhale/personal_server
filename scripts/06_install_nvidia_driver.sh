#!/usr/bin/env bash
# scripts/06_install_nvidia_driver.sh — one NVIDIA module provider: Ubuntu's
# branch-pinned open DKMS driver, with its userspace on the same point release.
#
# Kernel and header post-install hooks rebuild the module for each new kernel, so
# neither unattended-upgrades nor a manual apt upgrade can leave a new kernel
# without a driver. Canonical's per-ABI prebuilt modules are not used: each one
# locks the driver to the release it was built against, and unattended-upgrades
# will not remove a package, so one old module stalls the whole NVIDIA stack
# while newer kernels keep arriving (seen with 7.0.0-34 on the reference host).
#
# Never install both providers. They own the same module, and DKMS then fails with
# "already installed", which wedged dpkg for 65 minutes on 2026-08-19.
#
# The RTX 5090 (Blackwell, compute capability 12.0) needs branch 555 or newer.
#
# Usage:
#   sudo bash scripts/06_install_nvidia_driver.sh           # install or repair
#   sudo bash scripts/06_install_nvidia_driver.sh --check   # read-only verification
#   sudo DRIVER_BRANCH=600 bash scripts/06_install_nvidia_driver.sh   # override

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions
DRIVER_BRANCH="${DRIVER_BRANCH:-$NVIDIA_DRIVER_BRANCH}"
DRIVER_PKG="nvidia-driver-${DRIVER_BRANCH}-open"
DKMS_PKG="nvidia-dkms-${DRIVER_BRANCH}-open"
UTILS_PKG="nvidia-utils-${DRIVER_BRANCH}"
HEADERS_META=linux-headers-generic-hwe-24.04
TRIAL_MARKER=/etc/default/grub.d/99-cte-kernel-upgrade.cfg

# Anything dpkg still tracks counts as present. A half-configured package is what
# a failed DKMS build leaves behind, so it must not be filtered out here.
present_packages() {
    { dpkg-query -W -f='${db:Status-Status} ${Package}\n' "$@" 2>/dev/null || true; } \
        | awk '$1 != "not-installed" && $1 != "config-files" {print $2}'
}

installed_generic_kernels() {
    present_packages 'linux-image-[0-9]*-generic' | sed 's/^linux-image-//'
}

prebuilt_providers() {
    present_packages 'linux-modules-nvidia-*'
}

# Prints the problem with one kernel's module, or nothing when it is correct.
module_problem() {
    local release="$1" expected="$2" filename version status
    if [[ ! -e "/lib/modules/$release/build/Makefile" ]]; then
        echo "matching headers are missing for $release"
        return
    fi
    filename="$(modinfo -k "$release" -F filename nvidia 2>/dev/null || true)"
    case "$filename" in
        /lib/modules/"$release"/updates/dkms/*|/usr/lib/modules/"$release"/updates/dkms/*) ;;
        *) echo "$release does not use the DKMS module: ${filename:-missing}"; return ;;
    esac
    version="$(modinfo -k "$release" -F version nvidia)"
    if [[ "$version" != "$expected" ]]; then
        echo "$release has NVIDIA $version, expected $expected"
        return
    fi
    if [[ "$(modinfo -k "$release" -F vermagic nvidia)" != "$release "* ]]; then
        echo "NVIDIA module kernel release mismatch for $release"
        return
    fi
    # Anything after "installed" is DKMS reporting a difference from the built module.
    status="$(dkms status -m nvidia -v "$expected" -k "$release")"
    if [[ "$status" != *": installed" ]]; then
        echo "DKMS has not installed NVIDIA $expected for $release: $status"
    fi
}

# The running and newest kernels must be correct: GRUB boots the newest. Older
# kernels only warn, because Ubuntu's dkms rebuilds just those two on a driver
# update, while the CUDA repository's dkms 3.4 rebuilds every kernel with headers.
verify_kernel_modules() {
    local audit
    audit="$(dpkg --audit 2>&1 || true)"
    [[ -z "$audit" ]] || die "dpkg is unfinished, which also blocks unattended upgrades; see README section 9: $audit"
    [[ -z "$(prebuilt_providers)" ]] \
        || die 'prebuilt NVIDIA module packages remain; do not mix module providers'
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$DKMS_PKG" 2>/dev/null)" == installed ]] \
        || die "$DKMS_PKG is not installed"
    local release expected newest running problem
    expected="$(dpkg-query -W -f='${Version}' "$DKMS_PKG")"
    expected="${expected#*:}"
    expected="${expected%%-*}"
    running="$(uname -r)"
    newest="$(installed_generic_kernels | sort -V | tail -n 1)"
    [[ -n "$newest" ]] || die 'no installed generic kernel found'
    while IFS= read -r release; do
        problem="$(module_problem "$release" "$expected")"
        if [[ -z "$problem" ]]; then
            info "$release: NVIDIA $expected, matching headers and DKMS registration"
        elif [[ "$release" == "$running" || "$release" == "$newest" ]]; then
            die "$problem"
        else
            warn "older kernel, not the boot default: $problem"
        fi
    done < <(installed_generic_kernels)
}

verify_gpu() {
    local installed loaded
    installed="$(modinfo -F version nvidia 2>/dev/null || true)"
    [[ -n "$installed" ]] || die "no NVIDIA module for the running kernel $(uname -r)"
    loaded="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
    [[ "$loaded" == "$installed" ]] \
        || die "reboot required: loaded NVIDIA ${loaded:-none}, installed NVIDIA $installed"
    nvidia-smi || die 'nvidia-smi failed; inspect the GPU and driver before accepting the upgrade'
}

# Let unattended-upgrades take the NVIDIA stack from noble-updates as well as
# noble-security: some driver releases never reach noble-security. The rest of
# noble-updates stays manual. The file content, including the older wording about
# prebuilt modules, stays byte-identical so reference hosts see no policy change.
configure_unattended_upgrades() {
    section "unattended-upgrades: NVIDIA stack from noble-updates"
    local conf=/etc/apt/apt.conf.d/51unattended-upgrades-nvidia pattern content dump
    # shellcheck disable=SC2016  # ${distro_*} are expanded by unattended-upgrades
    local -a patterns=(
        'origin=${distro_id},archive=${distro_codename}-updates,component=restricted'
        'origin=${distro_id},archive=${distro_codename}-updates,component=multiverse'
    )
    content="$(
        printf '// Written by scripts/06_install_nvidia_driver.sh: lets unattended-upgrades\n'
        printf '// install the NVIDIA driver and its prebuilt kernel modules from noble-updates.\n'
        printf 'Unattended-Upgrade::Origins-Pattern {\n'
        printf '        "%s";\n' "${patterns[@]}"
        printf '};'
    )"
    if [[ -f "$conf" && "$(cat "$conf")" == "$content" ]]; then
        info "$conf already configured"
    else
        printf '%s\n' "$content" >"$conf"
        chmod 0644 "$conf"
        info "wrote $conf"
    fi
    dump="$(apt-config dump Unattended-Upgrade::Origins-Pattern)"
    for pattern in "${patterns[@]}"; do
        grep -qF -- "\"$pattern\";" <<<"$dump" \
            || die "apt configuration does not carry Origins-Pattern \"$pattern\" after writing $conf"
    done
}

main() {
    require_root
    require_ubuntu_noble
    [[ "$DRIVER_BRANCH" =~ ^[0-9]+$ ]] || die 'DRIVER_BRANCH must be numeric'
    if [[ "$DRIVER_BRANCH" != "$NVIDIA_DRIVER_BRANCH" ]]; then
        warn "DRIVER_BRANCH=$DRIVER_BRANCH overrides the pinned branch ($NVIDIA_DRIVER_BRANCH)"
    fi
    local check_only=0
    case "${1:-}" in
        '') ;;
        --check) check_only=1 ;;
        *) die 'usage: 06_install_nvidia_driver.sh [--check]' ;;
    esac
    [[ "$#" -le 1 ]] || die 'unexpected arguments'
    if [[ "$check_only" == 1 ]]; then
        verify_kernel_modules
        verify_gpu
        return
    fi
    # During a kernel trial the fallback must stay driver-free. Installing headers
    # for every kernel here would give it a module.
    [[ ! -e "$TRIAL_MARKER" ]] || die "a kernel upgrade trial is in progress ($TRIAL_MARKER); use --check only"

    configure_unattended_upgrades
    section "NVIDIA $DRIVER_BRANCH: one DKMS provider"
    apt-get update
    local release provider header mark was_manual
    local -a headers=() removals=() original_manual=()
    mapfile -t original_manual < <(apt-mark showmanual)
    while IFS= read -r release; do
        [[ -n "$release" ]] && headers+=("linux-headers-$release")
    done < <(installed_generic_kernels)
    [[ "${#headers[@]}" -gt 0 ]] || die 'no installed generic kernel found'
    while IFS= read -r provider; do
        [[ -n "$provider" ]] && removals+=("$provider-")
    done < <(prebuilt_providers)
    # Make the selected branch the sole source-built provider as well.
    while IFS= read -r provider; do
        [[ -z "$provider" || "$provider" == "$DKMS_PKG" ]] || removals+=("$provider-")
    done < <(present_packages 'nvidia-dkms-*')

    # Build prerequisites come first in the same transaction because this step
    # precedes the developer toolchain. --no-install-recommends stops Ubuntu's dkms
    # pulling in the GA kernel headers. Naming the DKMS package selects it as provider.
    apt-get install -y --no-install-recommends build-essential gcc-13 \
        "$HEADERS_META" "${headers[@]}" "$DRIVER_PKG" "$DKMS_PKG" "$UTILS_PKG" "${removals[@]}"
    while IFS= read -r release; do
        [[ -n "$release" ]] && dkms autoinstall -k "$release"
    done < <(installed_generic_kernels)
    # A per-ABI header installed solely to build this driver should rotate out
    # with its kernel. Preserve intentional pre-existing manual marks.
    for header in "${headers[@]}"; do
        was_manual=0
        for mark in "${original_manual[@]}"; do
            [[ "$mark" != "$header" ]] || was_manual=1
        done
        if [[ "$was_manual" == 0 ]]; then
            apt-mark auto "$header"
        fi
    done
    verify_kernel_modules
    verify_gpu
    info "NVIDIA $DRIVER_BRANCH DKMS driver verified"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
