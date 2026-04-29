#!/usr/bin/env bash
# scripts/lib/versions.sh — pinned versions of every package and downloaded
# asset this repo installs.
#
# These are the EXACT versions verified working on the reference RTX 5090 box.
# Pinning makes a future fresh install land at bit-for-bit the same stack.
#
# Sourced by every install script via lib/common.sh. Never executed directly.
#
# To upgrade a component:
#   1. Edit the pin here.
#   2. Re-run the corresponding script on a test box.
#   3. Run scripts/02_validate_xorg_session.sh and the network_security audit.
#   4. Commit the change.
#
# The .deb SHA-256 values were computed at the time of original install:
#   sha256sum ~/Downloads/rustdesk-1.4.6-x86_64.deb
#   sha256sum ~/Downloads/teamviewer_amd64.deb

# -- NVIDIA proprietary driver (open kernel module variant) --------------------
# nvidia-driver-${BRANCH}-open metapackage and its DKMS + utils companions.
NVIDIA_DRIVER_BRANCH=595
NVIDIA_DRIVER_VERSION=595.58.03-0ubuntu0.24.04.1
NVIDIA_DKMS_VERSION=$NVIDIA_DRIVER_VERSION
NVIDIA_UTILS_VERSION=$NVIDIA_DRIVER_VERSION

# -- CUDA Toolkit (host) -------------------------------------------------------
# Metapackage + full version. Pulls in nvcc, libraries, headers, samples.
CUDA_TOOLKIT_METAPACKAGE=cuda-toolkit-13-0
CUDA_TOOLKIT_VERSION=13.0.3-1
# CUDA apt-keyring (gen 1.1, stable URL).
CUDA_KEYRING_URL=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb

# -- Docker CE and plugins -----------------------------------------------------
# All five pinned to the same upstream release (5:29.4.1) plus matching plugins.
DOCKER_CE_VERSION="5:29.4.1-1~ubuntu.24.04~noble"
DOCKER_CE_CLI_VERSION="5:29.4.1-1~ubuntu.24.04~noble"
CONTAINERD_IO_VERSION="2.2.3-1~ubuntu.24.04~noble"
DOCKER_BUILDX_PLUGIN_VERSION="0.33.0-1~ubuntu.24.04~noble"
DOCKER_COMPOSE_PLUGIN_VERSION="5.1.3-1~ubuntu.24.04~noble"

# -- NVIDIA Container Toolkit (Docker --gpus runtime) --------------------------
# All four toolkit packages pinned to the same release.
NVIDIA_CONTAINER_TOOLKIT_VERSION=1.19.0-1
LIBNVIDIA_CONTAINER1_VERSION=1.19.0-1
LIBNVIDIA_CONTAINER_TOOLS_VERSION=1.19.0-1
NVIDIA_CONTAINER_TOOLKIT_BASE_VERSION=1.19.0-1
# CUDA base image used for the GPU passthrough smoke test.
CUDA_SMOKE_TEST_IMAGE=nvidia/cuda:12.8.0-base-ubuntu24.04

# -- RustDesk client -----------------------------------------------------------
# Tag is the GitHub-flagged stable release. URL is built deterministically from
# the tag — we do NOT query the GitHub /releases/latest API at install time, so
# the install is reproducible regardless of what becomes "latest" later.
RUSTDESK_VERSION=1.4.6
RUSTDESK_DEB_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-x86_64.deb"
RUSTDESK_DEB_SHA256=0da46d7a7b252282ded5323f74319a10c1fa7271001d3b297b3def415c8c8f04

# -- TeamViewer (full client) --------------------------------------------------
# Pinned via the dl.teamviewer.com version-specific URL pattern. The plain
# download.teamviewer.com URL serves whatever is current and CANNOT be pinned;
# the dl.teamviewer.com path with version_15x/<file>_<version>_amd64.deb is the
# version-specific redirect target and IS stable.
TEAMVIEWER_VERSION=15.76.5
TEAMVIEWER_DEB_URL="https://dl.teamviewer.com/download/linux/version_15x/teamviewer_${TEAMVIEWER_VERSION}_amd64.deb"
TEAMVIEWER_DEB_SHA256=8e5b19ac8860272a0842164f67568c03f369b0cfc9a0056dc352bb0a22774b99

# -- Developer toolchain (intentionally unpinned) ------------------------------
# scripts/13_install_developer_toolchain.sh installs four components that are
# DELIBERATELY not version-pinned, because their upstream channels are the
# right update mechanism:
#   - apt dev tools  : track noble's normal apt-upgrade flow.
#   - rustup / Rust  : `rustup update` is the upstream way to track stable.
#   - uv (Astral)    : `uv self update` is the upstream way to track latest.
#   - VS Code        : `apt upgrade` against packages.microsoft.com is the
#                      upstream way; pinning would defeat the goal.
#
# Reference versions verified working at the time of original setup, kept here
# only as an audit trail (not consumed by the script):
#   # Rust stable as of 2026-04: 1.87.0 (rustup-init reports the channel)
#   # uv as of 2026-04: 0.6.x
#   # VS Code as of 2026-04: 1.99.x
