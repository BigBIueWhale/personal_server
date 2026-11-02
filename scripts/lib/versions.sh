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

# -- NVIDIA driver (open kernel module, single DKMS provider) -----------------
# The source and userspace stay on one point release within this branch.
# Standard kernel/header hooks rebuild it for later HWE kernels. Do not install
# per-ABI linux-modules-nvidia packages alongside nvidia-dkms-${BRANCH}-open.
# scripts/06 supplies its own compiler and headers, and verifies the running and
# newest kernels. It adds no APT source, repository key, pin or hold.
NVIDIA_DRIVER_BRANCH=595

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
# These are the exact packages the reference box runs. Engine + CLI 29.8.1
# include the 29.6.1 BuildKit seccomp/AppArmor-frontend and passwd/group parser
# fixes, the 29.6.2 BuildKit fixes, the 29.7.0 fix for CVE-2026-17106
# (go-archive path traversal and arbitrary file overwrite), and the 29.8.0
# AppArmor/SELinux rules that stop containers reaching host VMs over AF_VSOCK
# through the 32-bit socketcall(2) path.
#
# containerd 2.3.5 carries the fixes for CVE-2026-53495, GHSA-7jxh-36q5-gcqv
# and GHSA-rp3h-jf77-q9p4 (sensitive auth headers stripped when fetching
# descriptor URLs) and runc 1.5.1. Pin it explicitly: docker-ce's dependency
# permits older compatible containerd.io versions and therefore does not by
# itself keep this component at the tested version.
#
# buildx 0.37.1 and Compose 5.5.1 are the matching packages published by
# Docker's noble/stable apt repository.
DOCKER_CE_VERSION="5:29.8.1-1~ubuntu.24.04~noble"
DOCKER_CE_CLI_VERSION="5:29.8.1-1~ubuntu.24.04~noble"
CONTAINERD_IO_VERSION="2.3.5-1~ubuntu.24.04~noble"
DOCKER_BUILDX_PLUGIN_VERSION="0.37.1-1~ubuntu.24.04~noble"
DOCKER_COMPOSE_PLUGIN_VERSION="5.5.1-1~ubuntu.24.04~noble"

# -- NVIDIA Container Toolkit (Docker --gpus runtime) --------------------------
# All four toolkit packages pinned to the same release, the one the reference
# box runs. 1.20.0 and 1.20.1 list no security fixes; the container-escape CVEs
# (NVIDIAScape CVE-2025-23266/-23267 et al.) were already closed in 1.17.8.
NVIDIA_CONTAINER_TOOLKIT_VERSION=1.20.1-1
LIBNVIDIA_CONTAINER1_VERSION=1.20.1-1
LIBNVIDIA_CONTAINER_TOOLS_VERSION=1.20.1-1
NVIDIA_CONTAINER_TOOLKIT_BASE_VERSION=1.20.1-1
# CUDA base image used for the GPU passthrough smoke test.
CUDA_SMOKE_TEST_IMAGE=nvidia/cuda:12.8.0-base-ubuntu24.04

# -- TeamViewer (full client) --------------------------------------------------
# Pinned via the dl.teamviewer.com version-specific URL pattern. The plain
# download.teamviewer.com URL serves whatever is current and CANNOT be pinned;
# the dl.teamviewer.com path with version_15x/<file>_<version>_amd64.deb is the
# version-specific redirect target and IS stable.
TEAMVIEWER_VERSION=15.81.5
TEAMVIEWER_DEB_URL="https://dl.teamviewer.com/download/linux/version_15x/teamviewer_${TEAMVIEWER_VERSION}_amd64.deb"
TEAMVIEWER_DEB_SHA256=59fd0c99f3a2e6bc975863a9a9e9d952ede499080909aaadfdf13a67f6eb31e2

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

# -- OpenAI Codex CLI ----------------------------------------------------------
# Standalone release installed by scripts/00_install_codex_cli.sh via
# https://chatgpt.com/codex/install.sh --release "$CODEX_CLI_VERSION".
# (--release is a documented flag of that installer; it also honours
# CODEX_NON_INTERACTIVE=1.)
#
# Keep this as an exact release pin. Before changing it, install and exercise the
# candidate release, run `codex --version` and `codex doctor`, complete a model
# turn, and confirm the installer's final managed-state check passes on a re-run.
#
# Codex can self-update in place, so the live release tree may drift past this
# pin. 00_install_codex_cli.sh prunes every non-pinned release directory and
# re-asserts this exact version whenever it runs.
CODEX_CLI_VERSION=0.159.0
