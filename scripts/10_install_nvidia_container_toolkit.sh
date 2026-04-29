#!/usr/bin/env bash
# scripts/10_install_nvidia_container_toolkit.sh — wire Docker to the NVIDIA runtime.
#
# After this script, `docker run --gpus all <image>` works: the container can
# see the host's NVIDIA GPU(s) via the 'nvidia' Docker runtime.
#
# Prerequisites (script enforces):
#   - NVIDIA driver loaded — installed by scripts/07_install_nvidia_driver.sh
#   - Docker installed and running — installed by scripts/09_install_docker.sh
#
# Sequence:
#   (1a) Add NVIDIA's libnvidia-container GPG key under /usr/share/keyrings.
#   (1b) Add NVIDIA's apt source list for the stable channel, transformed to
#        carry a 'signed-by' field pointing at our keyring (sed transform).
#   (1c) apt update + install nvidia-container-toolkit.
#   (2)  Run 'nvidia-ctk runtime configure --runtime=docker', which writes the
#        'nvidia' runtime entry into /etc/docker/daemon.json.
#   (3)  Restart Docker so the new runtime is loaded.
#   (4)  Smoke test: pull and run nvidia/cuda:12.8.0-base-ubuntu24.04 with
#        --gpus all and verify nvidia-smi works inside the container, showing
#        the same driver/CUDA version as the host.
#
# Usage:
#   sudo bash scripts/10_install_nvidia_container_toolkit.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_versions

require_root
require_ubuntu_noble
require_command curl
require_command nvidia-smi               # from scripts/07
require_command docker                   # from scripts/09
require_systemd_active docker.service    # daemon must be running

section "(1a) install NVIDIA libnvidia-container GPG key"
KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --batch --yes --dearmor -o "$KEYRING"
[ -s "$KEYRING" ] || die "GPG keyring at $KEYRING is empty after dearmor"
info "keyring written: $KEYRING"

section "(1b) add NVIDIA Container Toolkit apt source"
SOURCES_LIST=/etc/apt/sources.list.d/nvidia-container-toolkit.list
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
    > "$SOURCES_LIST"
[ -s "$SOURCES_LIST" ] || die "$SOURCES_LIST is empty after sed transform"
info "wrote $SOURCES_LIST:"
cat "$SOURCES_LIST"

section "(1c) apt update + install nvidia-container-toolkit (pinned)"
apt-get update
apt-get install -y \
    "nvidia-container-toolkit=$NVIDIA_CONTAINER_TOOLKIT_VERSION" \
    "nvidia-container-toolkit-base=$NVIDIA_CONTAINER_TOOLKIT_BASE_VERSION" \
    "libnvidia-container1=$LIBNVIDIA_CONTAINER1_VERSION" \
    "libnvidia-container-tools=$LIBNVIDIA_CONTAINER_TOOLS_VERSION"

section "(2) configure Docker to use the 'nvidia' runtime"
nvidia-ctk runtime configure --runtime=docker
[ -f /etc/docker/daemon.json ] || die "/etc/docker/daemon.json not created by nvidia-ctk"
info "/etc/docker/daemon.json:"
cat /etc/docker/daemon.json
# Verify the 'nvidia' runtime is registered.
if ! grep -q '"nvidia"' /etc/docker/daemon.json; then
    die "/etc/docker/daemon.json does not contain a 'nvidia' runtime entry"
fi

section "(3) restart Docker"
systemctl restart docker.service
require_systemd_active docker.service

section "(4) smoke test: nvidia-smi inside CUDA container"
# Image is pinned in lib/versions.sh as CUDA_SMOKE_TEST_IMAGE. We use a CUDA
# *base* image because it's small (~300 MB) and contains nvidia-smi. The driver
# branch we install can always run older CUDA-runtime containers; the reverse
# is not guaranteed.
docker run --rm --gpus all "$CUDA_SMOKE_TEST_IMAGE" nvidia-smi

section "success — Docker can now access the NVIDIA GPU via --gpus all"
