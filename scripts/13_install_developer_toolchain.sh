#!/usr/bin/env bash
# scripts/13_install_developer_toolchain.sh — install the developer toolchain.
#
# Single-script installer for everything needed to build, debug, and edit code
# on this box. Runs four phases in sequence; each is independently idempotent
# and safe to re-run:
#
#   (a) apt dev tools  — curl git gitk build-essential make cmake perl
#                        python3-pip net-tools (stock noble packages, unpinned
#                        on purpose — these track normal apt-upgrade flow).
#   (b) Rust via rustup — official upstream installer from sh.rustup.rs, run as
#                        $SUDO_USER so the toolchain lands in the user's
#                        ~/.cargo/ and ~/.rustup/, not root's. Always latest
#                        stable; rustup self-updates.
#   (c) uv (Astral)    — Astral's Python package/project manager, official
#                        installer from astral.sh, run as $SUDO_USER so the
#                        binary lands in ~/.local/bin/uv.
#   (d) VS Code        — Microsoft's apt repo at packages.microsoft.com, in
#                        Deb822 format, with the deb's debconf 'add-microsoft-
#                        repo' question pre-seeded. Unpinned on purpose; the
#                        whole point is fresh versions via apt upgrade.
#
# Usage:
#   sudo bash scripts/13_install_developer_toolchain.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu_noble
require_command curl
require_command apt-get
require_sudo_user

TARGET_USER="$SUDO_USER"
TARGET_HOME="$(sudo_user_home)"

# ---------------------------------------------------------------------------
# (a) apt dev tools
# ---------------------------------------------------------------------------
#
# A small smoke check at the end confirms a representative subset of binaries
# landed on PATH. apt's own exit code already proves the .debs installed; the
# smoke check catches package renames.

section "(a) apt dev tools"

APT_PACKAGES=(
    curl
    git
    gitk
    build-essential
    make
    cmake
    perl
    python3-pip
    net-tools
)

apt-get update
apt-get install -y "${APT_PACKAGES[@]}"

for cmd in curl git gitk gcc make cmake perl pip3 ifconfig; do
    require_command "$cmd"
done
info "apt dev tools installed and on PATH"

# ---------------------------------------------------------------------------
# (b) Rust via rustup
# ---------------------------------------------------------------------------
#
# Run as the desktop user so the toolchain lands in ~/.cargo/ and ~/.rustup/.
# Running rustup-init as root would put it in /root/, useless to the user.
# Re-running is harmless: rustup-init detects an existing installation and
# updates it, and `--profile default` matches the canonical layout.
#
# We deliberately do NOT version-pin Rust. The rustup channel mechanism is the
# upstream-blessed way to track stable; pinning a specific 1.x release here
# would defeat the point.

section "(b) Rust via rustup (as $TARGET_USER, latest stable)"

# -y          non-interactive
# --default-toolchain stable    install the stable channel
# --profile default             rustc, cargo, rust-std, rust-docs, rustfmt, clippy
sudo -u "$TARGET_USER" bash -lc '
    set -Eeuo pipefail
    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile default
'

# Verify under a login shell so ~/.cargo/env is sourced (rustup-init appends a
# block to ~/.bashrc and writes ~/.cargo/env; -lc picks both up).
sudo -u "$TARGET_USER" bash -lc 'rustc --version; cargo --version'
info "Rust toolchain installed under $TARGET_HOME/.cargo and $TARGET_HOME/.rustup"

# ---------------------------------------------------------------------------
# (c) uv (Astral)
# ---------------------------------------------------------------------------
#
# Astral's recommended one-liner from astral.sh. Installs to ~/.local/bin/uv
# when run as the user. Idempotent: re-running upgrades in place.
#
# Not version-pinned for the same reason as Rust — uv is the upstream channel.

section "(c) uv (Astral) (as $TARGET_USER)"

sudo -u "$TARGET_USER" bash -lc '
    set -Eeuo pipefail
    curl -LsSf https://astral.sh/uv/install.sh | sh
'

sudo -u "$TARGET_USER" bash -lc 'uv --version'
info "uv installed under $TARGET_HOME/.local/bin"

# ---------------------------------------------------------------------------
# (d) VS Code via Microsoft's apt repo
# ---------------------------------------------------------------------------
#
# Why apt repo over the alternatives:
#   - Microsoft apt repo (this): integrates with apt, auto-updates on
#     `apt upgrade`, no sandbox indirection.
#   - Snap: slow startup; sandbox restricts host toolchain access (gcc, venvs,
#     docker socket).
#   - Flathub: community-maintained (not Microsoft); same sandbox awkwardness.
#   - Standalone .deb: no apt source line, so apt upgrade doesn't update it.
#
# The 'code' package's postinst asks (via debconf) whether to add Microsoft's
# apt repo. We've already added it — pre-seeding the answer to 'true' just
# silences the prompt for non-interactive runs.

section "(d) VS Code prerequisites (ca-certificates, gpg, apt-transport-https)"
apt-get install -y ca-certificates gpg apt-transport-https debconf-utils

section "(d) Microsoft signing key under /etc/apt/keyrings"
install -m 0755 -d /etc/apt/keyrings
KEYRING=/etc/apt/keyrings/packages.microsoft.gpg
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --batch --yes --dearmor -o "$KEYRING"
chmod a+r "$KEYRING"
[ -s "$KEYRING" ] || die "Microsoft GPG keyring at $KEYRING is empty after dearmor"
info "keyring written: $KEYRING"

section "(d) /etc/apt/sources.list.d/vscode.sources (Deb822)"
ARCH="$(dpkg --print-architecture)"
[ -n "$ARCH" ] || die "could not determine architecture from dpkg"

cat >/etc/apt/sources.list.d/vscode.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: $ARCH
Signed-By: $KEYRING
EOF
info "/etc/apt/sources.list.d/vscode.sources:"
cat /etc/apt/sources.list.d/vscode.sources

section "(d) pre-seed debconf: 'code/add-microsoft-repo' = true"
echo "code code/add-microsoft-repo boolean true" | debconf-set-selections

section "(d) apt update + install code (intentionally unpinned)"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y code

require_command code
info "code --version:"
code --version

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

section "success — developer toolchain installed"
info "open a new shell (or 'source ~/.bashrc') so rustup's PATH and uv's PATH"
info "are picked up. Future 'apt upgrade' keeps VS Code current; 'rustup update'"
info "keeps Rust current; 'uv self update' keeps uv current."
