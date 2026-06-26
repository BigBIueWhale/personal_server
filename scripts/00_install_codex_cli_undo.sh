#!/usr/bin/env bash
# scripts/00_install_codex_cli_undo.sh - defensively undo the per-user Codex
# CLI configuration written by 00_install_codex_cli.sh.
#
# WHAT IT UNDOES
# --------------
#   (c) Deletes ~/.codex/config.toml ONLY IF it exists with the exact byte
#       content written by the installer. Different user config is preserved and
#       causes a loud refusal.
#   (b) Removes the exact ~/.bashrc PATH snippet written by the installer, if
#       present. If ~/.local/bin was already on PATH before install, there is
#       nothing to remove.
#   (a) Does NOT uninstall the Codex binary/package and never touches auth,
#       sessions, logs, history, plugins, MCP config, themes, or any other Codex
#       state under ~/.codex.
#
# DESIGN - TWO-PHASE, ALL-OR-NOTHING
# ----------------------------------
# Phase 1 verifies exact byte sequences and collects every problem before any
# write. If there is a problem, the script exits non-zero and touches nothing.
# Phase 2 performs removals with tempfile + atomic rename where a rewrite is
# needed.
#
# Usage:
#   bash scripts/00_install_codex_cli_undo.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_ubuntu_noble
require_command python3

TARGET_USER="$(id -un)"
TARGET_HOME="$HOME"
[ "$TARGET_HOME" = "/home/$TARGET_USER" ] \
    || die "expected HOME=/home/$TARGET_USER, got '$TARGET_HOME' - refusing to write into a non-standard home"

if [ -n "${CODEX_HOME:-}" ] && [ "$CODEX_HOME" != "$TARGET_HOME/.codex" ]; then
    die "CODEX_HOME is set to '$CODEX_HOME'. This undo script manages the default $TARGET_HOME/.codex only; unset CODEX_HOME and re-run."
fi

BASHRC="$TARGET_HOME/.bashrc"
CODEX_HOME_DIR="$TARGET_HOME/.codex"
CONFIG="$CODEX_HOME_DIR/config.toml"

[ -f "$BASHRC" ] || die "$BASHRC does not exist - nothing to undo for PATH step"

section "verify Codex managed state before undo"

export U_BASHRC="$BASHRC"
export U_CONFIG="$CONFIG"
python3 - <<'PYEOF'
from __future__ import annotations

import os
import pathlib
import sys
import tempfile

BASHRC = pathlib.Path(os.environ["U_BASHRC"])
CONFIG = pathlib.Path(os.environ["U_CONFIG"])

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

STEP_B_APPEND = (
    "\n"
    "# Added by 00_install_codex_cli.sh - codex lives in ~/.local/bin\n"
    "export PATH=\"$HOME/.local/bin:$PATH\"\n"
)

problems: list[str] = []
config_text = ""
if CONFIG.exists():
    if not CONFIG.is_file():
        problems.append(f"{CONFIG}: exists but is not a regular file")
    else:
        config_text = CONFIG.read_text(encoding="utf-8")
        if config_text != MANAGED_CONFIG:
            problems.append(f"{CONFIG}: content differs from installer-managed bytes")
else:
    problems.append(f"{CONFIG}: managed config is missing")

bashrc_text = BASHRC.read_text(encoding="utf-8")
n_b = bashrc_text.count(STEP_B_APPEND)
if n_b > 1:
    problems.append(f"{BASHRC}: Codex PATH snippet appears {n_b} times; expected 0 or 1")

if problems:
    print("[fatal] Phase 1 verification failed - refusing to undo anything.", file=sys.stderr)
    print("        No file has been touched. Problems:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(2)

print("[info] Phase 1: managed Codex config verified.")

CONFIG.unlink()
print(f"[info] deleted exact managed config {CONFIG}")

if n_b == 1:
    new_bashrc = bashrc_text.replace(STEP_B_APPEND, "", 1)
    fd, tmp = tempfile.mkstemp(prefix=BASHRC.name + ".new.", dir=str(BASHRC.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_bashrc)
        os.replace(tmp, BASHRC)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    print(f"[info] removed Codex PATH snippet from {BASHRC}")
else:
    print(f"[info] no installer-owned Codex PATH snippet in {BASHRC}; leaving PATH config alone")

print("[info] Codex managed configuration undo complete")
PYEOF

section "success - Codex CLI configuration reverted"
info "Codex binary/package, auth, sessions, logs, history, plugins, MCP config,"
info "and all unmanaged ~/.codex state were intentionally preserved."
