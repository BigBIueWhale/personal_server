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
#   3. Run scripts/01_validate_xorg_session.sh and the network_security audit.
#   4. Commit the change.
#
# The .deb SHA-256 values were computed at the time of original install:
#   sha256sum ~/Downloads/teamviewer_amd64.deb

# -- NVIDIA proprietary driver (open kernel module variant) --------------------
# nvidia-driver-${BRANCH}-open metapackage and its DKMS + utils companions.
NVIDIA_DRIVER_BRANCH=595
NVIDIA_DRIVER_VERSION=595.71.05-0ubuntu0.24.04.1
NVIDIA_DKMS_VERSION=$NVIDIA_DRIVER_VERSION
NVIDIA_UTILS_VERSION=$NVIDIA_DRIVER_VERSION

# -- CUDA Toolkit (host) -------------------------------------------------------
# Metapackage + full version. Pulls in nvcc, libraries, headers, samples.
# Held at 13.0.3 (latest 13.0 patch). The 595 driver supports CUDA <= 13.2;
# CUDA 13.3 requires driver >= 610, which noble does not ship — do NOT bump the
# metapackage past cuda-toolkit-13-2 on this box.
CUDA_TOOLKIT_METAPACKAGE=cuda-toolkit-13-0
CUDA_TOOLKIT_VERSION=13.0.3-1
# CUDA apt-keyring (gen 1.1, stable URL).
CUDA_KEYRING_URL=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb

# -- Docker CE and plugins -----------------------------------------------------
# Engine + CLI on 29.5.3: 29.5.1 fixed the host-root `docker cp`/archive CVEs
# (CVE-2026-41567/-41568/-42306), but shipped a `docker cp` regression fixed in
# 29.5.2 — so pin the clean 29.5.3, not the bare minimum. containerd 2.2.4 fixes
# CVE-2026-46680 and is what 29.5.3 bundles; pin it explicitly (the docker-ce
# dependency allows but does not force it). buildx/compose tracked to current.
DOCKER_CE_VERSION="5:29.5.3-1~ubuntu.24.04~noble"
DOCKER_CE_CLI_VERSION="5:29.5.3-1~ubuntu.24.04~noble"
CONTAINERD_IO_VERSION="2.2.4-1~ubuntu.24.04~noble"
DOCKER_BUILDX_PLUGIN_VERSION="0.34.1-1~ubuntu.24.04~noble"
DOCKER_COMPOSE_PLUGIN_VERSION="5.1.4-1~ubuntu.24.04~noble"

# -- NVIDIA Container Toolkit (Docker --gpus runtime) --------------------------
# All four toolkit packages pinned to the same release. 1.19.1 is the latest
# stable (bug-fix only over 1.19.0; the container-escape CVEs — NVIDIAScape
# CVE-2025-23266/-23267 et al. — were already closed in 1.17.8).
NVIDIA_CONTAINER_TOOLKIT_VERSION=1.19.1-1
LIBNVIDIA_CONTAINER1_VERSION=1.19.1-1
LIBNVIDIA_CONTAINER_TOOLS_VERSION=1.19.1-1
NVIDIA_CONTAINER_TOOLKIT_BASE_VERSION=1.19.1-1
# CUDA base image used for the GPU passthrough smoke test.
CUDA_SMOKE_TEST_IMAGE=nvidia/cuda:12.8.0-base-ubuntu24.04

# -- TeamViewer (full client) --------------------------------------------------
# Pinned via the dl.teamviewer.com version-specific URL pattern. The plain
# download.teamviewer.com URL serves whatever is current and CANNOT be pinned;
# the dl.teamviewer.com path with version_15x/<file>_<version>_amd64.deb is the
# version-specific redirect target and IS stable.
TEAMVIEWER_VERSION=15.78.3
TEAMVIEWER_DEB_URL="https://dl.teamviewer.com/download/linux/version_15x/teamviewer_${TEAMVIEWER_VERSION}_amd64.deb"
TEAMVIEWER_DEB_SHA256=c2b98b22bf2a34bbdf5b930c8fa7da17fba195d83d0e3f9e0e695c9043aa9e6a

# -- Developer toolchain (intentionally unpinned) ------------------------------
# scripts/11_install_developer_toolchain.sh installs four components that are
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
