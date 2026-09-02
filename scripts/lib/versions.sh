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
# The kernel module is Canonical's prebuilt, signed
# linux-modules-nvidia-${BRANCH}-open-generic-hwe-24.04 package. It is versioned
# to the HWE kernel ABI (not the driver), built and signed by Canonical against
# each new HWE kernel, and shipped through noble-updates — so it loads under
# Secure Boot with no local signing key and follows the HWE kernel automatically
# on every kernel upgrade. Because that signed module is rebuilt against the
# current 595 point release for each kernel, the userspace nvidia-driver /
# nvidia-utils packages must track the same point release. NVIDIA is therefore
# pinned to a BRANCH, not a frozen point version: freezing userspace would
# desync it from the kernel-coupled module and break nvidia-smi on the next
# kernel bump. (This is the one stack that floats within its pin — everything
# else in this file is an exact-version pin.)
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
# Engine + CLI 29.7.2 include the 29.6.1 BuildKit seccomp/AppArmor-frontend and
# passwd/group parser fixes, the 29.6.2 BuildKit fixes, and the 29.7.0 fix for
# CVE-2026-17106 (go-archive path traversal and arbitrary file overwrite).
#
# containerd 2.3.4 is the current Docker noble/stable patch release. Pin it
# explicitly: docker-ce's dependency permits older compatible containerd.io
# versions and therefore does not by itself keep this component at the tested
# version.
#
# buildx 0.36.1 and Compose 5.5.0 are the matching current packages published
# by Docker's noble/stable apt repository.
DOCKER_CE_VERSION="5:29.7.2-1~ubuntu.24.04~noble"
DOCKER_CE_CLI_VERSION="5:29.7.2-1~ubuntu.24.04~noble"
CONTAINERD_IO_VERSION="2.3.4-1~ubuntu.24.04~noble"
DOCKER_BUILDX_PLUGIN_VERSION="0.36.1-1~ubuntu.24.04~noble"
DOCKER_COMPOSE_PLUGIN_VERSION="5.5.0-1~ubuntu.24.04~noble"

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

# -- OpenAI Codex CLI ----------------------------------------------------------
# Standalone release installed by scripts/00_install_codex_cli.sh via
# https://chatgpt.com/codex/install.sh --release "$CODEX_CLI_VERSION".
# (--release is a documented flag of that installer; it also honours
# CODEX_NON_INTERACTIVE=1.)
#
# 0.150.1 is the release actually running on the reference box, so it is what
# this repo pins. Installed there on 2026-08-27 by 00_install_codex_cli.sh (not
# by Codex's own self-update), and verified: `codex --version` reports 0.150.1,
# `codex doctor` is clean (19 ok / 0 warn / 0 fail, and no longer offers a newer
# release), and the installer's own final managed-state check passes on a
# re-run. A full model turn could NOT be exercised: the account's ChatGPT
# entitlement went Pro -> free on 2026-08-26, and gpt-5.6-sol has returned HTTP
# 400 on every client since - 0.145.0 and 0.150.1 alike - so that gate is an
# account fact, not a release regression. Do NOT bump this line without
# installing and exercising the release first; the pin records a verified
# version, not the newest one.
#
# Codex self-updates in place, so the release tree drifts past this pin on a
# live box. 00_install_codex_cli.sh prunes any non-pinned release directory back
# to this version rather than refusing, so re-running it re-asserts the pin.
CODEX_CLI_VERSION=0.150.1
