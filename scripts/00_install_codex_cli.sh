#!/usr/bin/env bash
# scripts/00_install_codex_cli.sh - install OpenAI Codex CLI and configure
# automation-first defaults for this personal Debian/Ubuntu box.
#
# WHY THIS EXISTS
# ---------------
# This machine's intended Codex usage is closer to classic:
#   claude --dangerously-skip-permissions
# than to a profile-picker workflow. Codex's equivalent durable settings are
# approval_policy="never" plus sandbox_mode="danger-full-access" in
# ~/.codex/config.toml. This script writes one direct, exact, managed config file
# instead of creating profiles, and it runs the upstream installer in explicit
# non-interactive mode for automation.
#
# WHAT IT DOES (idempotently)
# ---------------------------
#   (a) Install Codex CLI with OpenAI's documented standalone installer at
#       https://chatgpt.com/codex/install.sh, expecting ~/.local/bin/codex.
#       The installer is invoked with CODEX_NON_INTERACTIVE=1. If another codex
#       earlier/on PATH is not that binary, this script refuses.
#   (b) Ensure ~/.local/bin is on PATH via ~/.bashrc, only if no export PATH line
#       already mentions .local/bin.
#   (c) Write ~/.codex/config.toml as one exact managed file, but ONLY if it is
#       absent, empty, or already exactly matches this script's desired bytes.
#       Any different existing config causes a loud refusal. This avoids unsafe
#       TOML surgery and avoids the profile indirection the previous draft used.
#
# IDEMPOTENCY
# -----------
# Already correct -> no-op; absent/empty -> write; conflicting -> refuse loudly.
# This script never silently overwrites existing Codex config, auth, sessions,
# logs, history, MCP servers, plugins, or other accumulated state.
#
# RUN AS THE DESKTOP USER (NOT sudo)
# ----------------------------------
# Codex installs into ~/.local/bin and stores config/state under ~/.codex. Running
# as root would configure /root, not the desktop user. This script enforces
# require_non_root and the repo's Ubuntu noble target.
#
# Usage:
#   bash scripts/00_install_codex_cli.sh
#
# After it finishes, open a new shell (or `source ~/.bashrc`) and run `codex`.
# Use `/status` inside Codex to verify model, approval policy, and sandbox.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_ubuntu_noble
require_command curl
require_command python3

TARGET_USER="$(id -un)"
TARGET_HOME="$HOME"
[ "$TARGET_HOME" = "/home/$TARGET_USER" ] \
    || die "expected HOME=/home/$TARGET_USER, got '$TARGET_HOME' - refusing to write into a non-standard home"

if [ -n "${CODEX_HOME:-}" ] && [ "$CODEX_HOME" != "$TARGET_HOME/.codex" ]; then
    die "CODEX_HOME is set to '$CODEX_HOME'. This installer manages the default $TARGET_HOME/.codex only; unset CODEX_HOME and re-run."
fi

BASHRC="$TARGET_HOME/.bashrc"
[ -f "$BASHRC" ] || die "$BASHRC does not exist - this script edits .bashrc and cannot proceed"

LOCAL_BIN="$TARGET_HOME/.local/bin"
CODEX_BIN="$LOCAL_BIN/codex"
CODEX_HOME_DIR="$TARGET_HOME/.codex"
CONFIG="$CODEX_HOME_DIR/config.toml"
INSTALLER_URL="https://chatgpt.com/codex/install.sh"

# ---------------------------------------------------------------------------
# (a) install Codex CLI via OpenAI's standalone installer, non-interactively
# ---------------------------------------------------------------------------

section "(a) install Codex CLI via $INSTALLER_URL"

if command -v codex >/dev/null 2>&1; then
    FOUND_CODEX="$(command -v codex)"
    if [ "$FOUND_CODEX" != "$CODEX_BIN" ]; then
        die "found codex at '$FOUND_CODEX', but this installer manages '$CODEX_BIN'. Refusing to shadow or replace a different Codex install."
    fi
fi

if [ -e "$CODEX_BIN" ]; then
    [ -x "$CODEX_BIN" ] || die "$CODEX_BIN exists but is not executable - refusing to touch it"
    info "$CODEX_BIN already exists - skipping installer (re-run is idempotent)"
else
    info "downloading and running $INSTALLER_URL with CODEX_NON_INTERACTIVE=1"
    curl -fsSL "$INSTALLER_URL" | CODEX_NON_INTERACTIVE=1 sh
    [ -x "$CODEX_BIN" ] \
        || die "after running installer, $CODEX_BIN does not exist or is not executable - installer must have failed"
fi

VER_LINE="$("$CODEX_BIN" --version 2>&1 | head -1 || true)"
[ -n "$VER_LINE" ] || die "'$CODEX_BIN --version' produced no output"
info "codex --version: $VER_LINE"

# ---------------------------------------------------------------------------
# (b) ensure ~/.local/bin is on PATH in ~/.bashrc
# ---------------------------------------------------------------------------

section "(b) ~/.local/bin on PATH in $BASHRC"

if grep -Eq '^[[:space:]]*export[[:space:]]+PATH=.*\.local/bin' "$BASHRC"; then
    info "$BASHRC already has an 'export PATH=' line that references .local/bin - leaving alone"
else
    info "appending PATH export to $BASHRC (no existing reference to .local/bin found)"
    {
        printf '\n'
        printf '# Added by 00_install_codex_cli.sh - codex lives in ~/.local/bin\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$BASHRC"
fi

# ---------------------------------------------------------------------------
# (c) write one direct managed ~/.codex/config.toml (no profiles)
# ---------------------------------------------------------------------------

section "(c) configure direct automation-first Codex config in $CONFIG"

mkdir -p "$CODEX_HOME_DIR"

export C_CONFIG="$CONFIG"
python3 - <<'PYEOF'
from __future__ import annotations

import os
import pathlib
import sys
import tempfile
import tomllib

CONFIG = pathlib.Path(os.environ["C_CONFIG"])

MANAGED_CONFIG = """# Managed by scripts/00_install_codex_cli.sh.
# This file is intentionally direct root Codex config, not a profile. Do not edit
# by hand; edit the installer, delete this exact file, then re-run.
#
# Automation policy:
# - Pin model/reasoning to avoid alias/catalog/default drift.
# - Match the user's preferred no-permission-prompt workflow with
#   approval_policy="never" and sandbox_mode="danger-full-access".
# - Keep web search live for agent-side research when Codex supports it.
# - Harden child-process environment inheritance enough to avoid common secret
#   leakage while preserving core shell usability.
# - Disable prompt history persistence, analytics, feedback, and startup update
#   checks on this personal infrastructure workstation.

model = "gpt-5.5"
model_provider = "openai"
model_reasoning_effort = "xhigh"
plan_mode_reasoning_effort = "xhigh"
model_reasoning_summary = "auto"
model_verbosity = "high"

approval_policy = "never"
sandbox_mode = "danger-full-access"
web_search = "live"
file_opener = "none"
check_for_update_on_startup = false
hide_agent_reasoning = false
show_raw_agent_reasoning = false

[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false
exclude = [
  "*KEY*",
  "*SECRET*",
  "*TOKEN*",
  "AWS_*",
  "AZURE_*",
  "GITHUB_TOKEN",
  "OPENAI_API_KEY",
  "ANTHROPIC_API_KEY",
]
set = {}
include_only = []
experimental_use_profile = false

[history]
persistence = "none"

[analytics]
enabled = false

[feedback]
enabled = false
"""


def die(message: str) -> None:
    print(f"[fatal] {message}", file=sys.stderr)
    sys.exit(2)


def atomic_write(path: pathlib.Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".new.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

try:
    tomllib.loads(MANAGED_CONFIG)
except tomllib.TOMLDecodeError as e:
    die(f"internal error: managed Codex config is not valid TOML: {e}")

if CONFIG.exists():
    if not CONFIG.is_file():
        die(f"{CONFIG} exists but is not a regular file")
    existing = CONFIG.read_text(encoding="utf-8")
    if existing == MANAGED_CONFIG:
        print(f"[info] {CONFIG}: already present and matches expected bytes")
    elif existing.strip() == "":
        print(f"[info] {CONFIG}: empty - writing managed direct config")
        atomic_write(CONFIG, MANAGED_CONFIG)
    else:
        try:
            tomllib.loads(existing)
        except tomllib.TOMLDecodeError as e:
            die(f"{CONFIG} exists with different content and is not valid TOML: {e}. Refusing to overwrite.")
        die(
            f"{CONFIG} already exists with user/stale content. Refusing to overwrite. "
            "Move it aside or delete it manually if you want this script to manage Codex config."
        )
else:
    print(f"[info] {CONFIG}: creating managed direct config")
    atomic_write(CONFIG, MANAGED_CONFIG)

print("[info] managed Codex config TOML validation passed")
PYEOF

section "success - Codex CLI installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so PATH updates take effect."
info "Run 'codex' and verify active state with /status."
info "Managed default: approval_policy=never, sandbox_mode=danger-full-access."
