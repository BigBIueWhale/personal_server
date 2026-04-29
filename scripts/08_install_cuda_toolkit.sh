#!/usr/bin/env bash
# scripts/08_install_cuda_toolkit.sh — install the host-side CUDA Toolkit.
#
# This installs nvcc, CUDA headers, and CUDA libraries for compiling CUDA code
# natively on the host. Pre-built CUDA workloads (e.g., applications shipped
# with their own CUDA runtime libs) do NOT need this — only the driver.
# Install only if you intend to compile CUDA code on the host.
#
# Sequence:
#   1. Download NVIDIA's CUDA apt-keyring deb from developer.download.nvidia.com.
#   2. Install the keyring deb (it adds NVIDIA's apt source under
#      /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list and the GPG key).
#   3. apt update, apt install cuda-toolkit-13-0 (~3-4 GB).
#   4. Idempotently append the canonical PATH and LD_LIBRARY_PATH exports to
#      the invoking user's ~/.bashrc.
#   5. Verify nvcc -V works under the new PATH.
#
# Usage:
#   sudo bash scripts/08_install_cuda_toolkit.sh
#
# After this script succeeds, open a new shell (or 'source ~/.bashrc') so
# nvcc is on PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions

require_root
require_ubuntu_noble
require_command wget
require_command dpkg
require_sudo_user
require_command nvidia-smi   # provided by scripts/07_install_nvidia_driver.sh

TARGET_USER="$SUDO_USER"
TARGET_HOME="$(sudo_user_home)"
BASHRC="$TARGET_HOME/.bashrc"
[ -f "$BASHRC" ] || die "$BASHRC does not exist"

KEYRING_DEB=/tmp/cuda-keyring_1.1-1_all.deb

section "fetching cuda-keyring"
wget --show-progress -O "$KEYRING_DEB" "$CUDA_KEYRING_URL"
[ -s "$KEYRING_DEB" ] || die "downloaded keyring file is empty"

section "installing cuda-keyring"
dpkg -i "$KEYRING_DEB"

section "apt update"
apt-get update

section "apt install ${CUDA_TOOLKIT_METAPACKAGE}=${CUDA_TOOLKIT_VERSION}  (~3-4 GB; this is the slow step)"
apt-get install -y "${CUDA_TOOLKIT_METAPACKAGE}=${CUDA_TOOLKIT_VERSION}"

# Confirm /usr/local/cuda exists (CUDA installs into /usr/local/cuda-13.0 and
# the metapackage creates the /usr/local/cuda symlink).
[ -d /usr/local/cuda/bin ] || die "/usr/local/cuda/bin not found after install"
[ -x /usr/local/cuda/bin/nvcc ] || die "/usr/local/cuda/bin/nvcc is not executable"

section "appending CUDA env to $BASHRC (idempotent)"

# Use grep -qF (fixed-string) on the canonical substring, not the full line, so
# manual edits with extra whitespace or formatting don't trigger duplication.
if grep -qF '/usr/local/cuda/bin' "$BASHRC"; then
    info "PATH already references /usr/local/cuda/bin — skipping"
else
    sudo -u "$TARGET_USER" bash -c "echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> '$BASHRC'"
    info "appended PATH"
fi

if grep -qF '/usr/local/cuda/lib64' "$BASHRC"; then
    info "LD_LIBRARY_PATH already references /usr/local/cuda/lib64 — skipping"
else
    sudo -u "$TARGET_USER" bash -c "echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH' >> '$BASHRC'"
    info "appended LD_LIBRARY_PATH"
fi

section "verification (nvcc -V via the new PATH)"
PATH=/usr/local/cuda/bin:$PATH nvcc -V

section "success"
info "open a new shell, or run 'source ~/.bashrc', to pick up nvcc on PATH."
