#!/usr/bin/env bash
# scripts/00_install_codex_cli.sh — install OpenAI Codex CLI and configure
# conservative, source-audited defaults for this personal Debian/Ubuntu box.
#
# WHY THIS EXISTS
# ---------------
# Codex CLI is configurable in ~/.codex/config.toml and profile files, but the
# defaults are deliberately developer-convenience oriented in several places:
# trusted projects can resolve to workspace-write, shell commands inherit more
# environment than this repo's security posture wants, prompt history/analytics
# are on by default, and startup update checks are automatic. This script pins a
# defensive profile instead of relying on product defaults or aliases.
#
# WHAT IT DOES (idempotently)
# ---------------------------
#   (a) Install Codex CLI with OpenAI's documented standalone installer at
#       https://chatgpt.com/codex/install.sh, expecting ~/.local/bin/codex.
#       If another codex earlier/on PATH is not that binary, the script refuses.
#   (b) Ensure ~/.local/bin is on PATH via ~/.bashrc, only if no export PATH line
#       already mentions .local/bin.
#   (c) Ensure ~/.codex/config.toml selects the managed safe profile. If a
#       different root profile already exists, the script refuses. If no root
#       profile exists, it prepends a marker-delimited root TOML block so the key
#       is definitely at TOML root rather than accidentally inside the last table.
#   (d) Create three exact managed profile files:
#       - personal-server-safe.config.toml: default read-only, high-reasoning,
#         no history/analytics/feedback, hardened shell environment.
#       - personal-server-workspace.config.toml: explicit workspace-write, still
#         no sandboxed network and no /tmp writable roots.
#       - personal-server-container-danger.config.toml: yolo-style container-only
#         profile with danger-full-access and approval_policy=never.
#       Existing profile files must match byte-for-byte or the script refuses.
#
# IDEMPOTENCY
# -----------
# Every managed write follows the same policy as the Claude installer: already
# correct -> no-op; absent -> write; conflicting -> refuse loudly. This script
# never silently overwrites user Codex config, auth, sessions, logs, history,
# MCP servers, plugins, or other accumulated state.
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
# Use `/status` inside Codex to verify the active model, approval policy, and
# sandbox. For editing in a trusted repo, run `codex --profile personal-server-workspace`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_ubuntu_noble
require_command curl
require_command python3

TARGET_USER="$(id -un)"
TARGET_HOME="$HOME"
[ "$TARGET_HOME" = "/home/$TARGET_USER" ] \
    || die "expected HOME=/home/$TARGET_USER, got '$TARGET_HOME' — refusing to write into a non-standard home"

if [ -n "${CODEX_HOME:-}" ] && [ "$CODEX_HOME" != "$TARGET_HOME/.codex" ]; then
    die "CODEX_HOME is set to '$CODEX_HOME'. This installer manages the default $TARGET_HOME/.codex only; unset CODEX_HOME and re-run."
fi

BASHRC="$TARGET_HOME/.bashrc"
[ -f "$BASHRC" ] || die "$BASHRC does not exist — this script edits .bashrc and cannot proceed"

LOCAL_BIN="$TARGET_HOME/.local/bin"
CODEX_BIN="$LOCAL_BIN/codex"
CODEX_HOME_DIR="$TARGET_HOME/.codex"
CONFIG="$CODEX_HOME_DIR/config.toml"
SAFE_PROFILE="$CODEX_HOME_DIR/personal-server-safe.config.toml"
WORKSPACE_PROFILE="$CODEX_HOME_DIR/personal-server-workspace.config.toml"
DANGER_PROFILE="$CODEX_HOME_DIR/personal-server-container-danger.config.toml"

INSTALLER_URL="https://chatgpt.com/codex/install.sh"

# ---------------------------------------------------------------------------
# (a) install Codex CLI via OpenAI's standalone installer
# ---------------------------------------------------------------------------

section "(a) install Codex CLI via $INSTALLER_URL"

if command -v codex >/dev/null 2>&1; then
    FOUND_CODEX="$(command -v codex)"
    if [ "$FOUND_CODEX" != "$CODEX_BIN" ]; then
        die "found codex at '$FOUND_CODEX', but this installer manages '$CODEX_BIN'. Refusing to shadow or replace a different Codex install."
    fi
fi

if [ -e "$CODEX_BIN" ]; then
    [ -x "$CODEX_BIN" ] || die "$CODEX_BIN exists but is not executable — refusing to touch it"
    info "$CODEX_BIN already exists — skipping installer (re-run is idempotent)"
else
    info "downloading and running $INSTALLER_URL"
    curl -fsSL "$INSTALLER_URL" | sh
    [ -x "$CODEX_BIN" ] \
        || die "after running installer, $CODEX_BIN does not exist or is not executable — installer must have failed"
fi

VER_LINE="$("$CODEX_BIN" --version 2>&1 | head -1 || true)"
[ -n "$VER_LINE" ] || die "'$CODEX_BIN --version' produced no output"
info "codex --version: $VER_LINE"

# ---------------------------------------------------------------------------
# (b) ensure ~/.local/bin is on PATH in ~/.bashrc
# ---------------------------------------------------------------------------

section "(b) ~/.local/bin on PATH in $BASHRC"

if grep -Eq '^[[:space:]]*export[[:space:]]+PATH=.*\.local/bin' "$BASHRC"; then
    info "$BASHRC already has an 'export PATH=' line that references .local/bin — leaving alone"
else
    info "appending PATH export to $BASHRC (no existing reference to .local/bin found)"
    {
        printf '\n'
        printf '# Added by 00_install_codex_cli.sh — codex lives in ~/.local/bin\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$BASHRC"
fi

# ---------------------------------------------------------------------------
# (c)+(d) manage ~/.codex/config.toml and profile files
# ---------------------------------------------------------------------------

section "(c)+(d) configure defensive Codex profiles under $CODEX_HOME_DIR"

mkdir -p "$CODEX_HOME_DIR"
if [ ! -e "$CONFIG" ]; then
    info "$CONFIG does not exist — initializing with empty file"
    : > "$CONFIG"
fi
[ -f "$CONFIG" ] || die "$CONFIG exists but is not a regular file"

export C_CONFIG="$CONFIG"
export C_SAFE_PROFILE="$SAFE_PROFILE"
export C_WORKSPACE_PROFILE="$WORKSPACE_PROFILE"
export C_DANGER_PROFILE="$DANGER_PROFILE"

python3 - <<'PYEOF'
from __future__ import annotations

import os
import pathlib
import sys
import tempfile
import tomllib

CONFIG = pathlib.Path(os.environ["C_CONFIG"])
SAFE_PROFILE = pathlib.Path(os.environ["C_SAFE_PROFILE"])
WORKSPACE_PROFILE = pathlib.Path(os.environ["C_WORKSPACE_PROFILE"])
DANGER_PROFILE = pathlib.Path(os.environ["C_DANGER_PROFILE"])

PROFILE_NAME = "personal-server-safe"

ROOT_BEGIN = "# >>> codex config profile (managed by 00_install_codex_cli.sh) >>>"
ROOT_END = "# <<< codex config profile (managed by 00_install_codex_cli.sh) <<<"
ROOT_BLOCK = f"""{ROOT_BEGIN}
# Select the conservative host-safe profile by default. Do not edit this block
# by hand; delete the whole block and re-run the installer if you want it
# recreated. Project, thread, runtime, and CLI overrides can still supersede
# this selection, so verify effective state with /status inside Codex.
profile = \"{PROFILE_NAME}\"
{ROOT_END}
"""

COMMON_HEADER = """# Managed by scripts/00_install_codex_cli.sh.
# Do not edit this file by hand. Re-run the installer to recreate it, or run
# scripts/00_install_codex_cli_undo.sh to remove only exact managed state.
#
# Source-audited rationale:
# - Pin model/reasoning to avoid alias/catalog/default drift.
# - Avoid trusted-project workspace-write as the default host posture.
# - Harden spawned shell environment so secrets are not inherited by default.
# - Disable prompt history persistence, analytics, feedback, and startup update
#   checks on this personal infrastructure workstation.

"""

SAFE_CONTENT = COMMON_HEADER + """model = \"gpt-5.5\"
model_provider = \"openai\"
model_reasoning_effort = \"xhigh\"
plan_mode_reasoning_effort = \"xhigh\"
model_reasoning_summary = \"auto\"
model_verbosity = \"high\"

approval_policy = \"on-request\"
sandbox_mode = \"read-only\"
web_search = \"disabled\"
file_opener = \"none\"
check_for_update_on_startup = false
hide_agent_reasoning = false
show_raw_agent_reasoning = false

[shell_environment_policy]
inherit = \"core\"
ignore_default_excludes = false
exclude = [
  \"*KEY*\",
  \"*SECRET*\",
  \"*TOKEN*\",
  \"AWS_*\",
  \"AZURE_*\",
  \"GITHUB_TOKEN\",
  \"OPENAI_API_KEY\",
  \"ANTHROPIC_API_KEY\",
]
set = {}
include_only = []
experimental_use_profile = false

[history]
persistence = \"none\"

[analytics]
enabled = false

[feedback]
enabled = false
"""

WORKSPACE_CONTENT = COMMON_HEADER + """model = \"gpt-5.5\"
model_provider = \"openai\"
model_reasoning_effort = \"xhigh\"
plan_mode_reasoning_effort = \"xhigh\"
model_reasoning_summary = \"auto\"
model_verbosity = \"high\"

approval_policy = \"on-request\"
sandbox_mode = \"workspace-write\"
web_search = \"disabled\"
file_opener = \"none\"
check_for_update_on_startup = false

[sandbox_workspace_write]
writable_roots = []
network_access = false
exclude_tmpdir_env_var = true
exclude_slash_tmp = true

[shell_environment_policy]
inherit = \"core\"
ignore_default_excludes = false
exclude = [
  \"*KEY*\",
  \"*SECRET*\",
  \"*TOKEN*\",
  \"AWS_*\",
  \"AZURE_*\",
  \"GITHUB_TOKEN\",
  \"OPENAI_API_KEY\",
  \"ANTHROPIC_API_KEY\",
]
set = {}
include_only = []
experimental_use_profile = false

[history]
persistence = \"none\"

[analytics]
enabled = false

[feedback]
enabled = false
"""

DANGER_CONTENT = COMMON_HEADER + """# CONTAINER/VM ONLY. This disables Codex's approvals and sandbox. Use only in a
# disposable Docker/VM/container that provides the real containment boundary.
model = \"gpt-5.5\"
model_provider = \"openai\"
model_reasoning_effort = \"xhigh\"
plan_mode_reasoning_effort = \"xhigh\"
model_reasoning_summary = \"auto\"
model_verbosity = \"high\"

approval_policy = \"never\"
sandbox_mode = \"danger-full-access\"
web_search = \"live\"
file_opener = \"none\"
check_for_update_on_startup = false

[shell_environment_policy]
inherit = \"core\"
ignore_default_excludes = false
exclude = [
  \"*KEY*\",
  \"*SECRET*\",
  \"*TOKEN*\",
  \"AWS_*\",
  \"AZURE_*\",
  \"GITHUB_TOKEN\",
  \"OPENAI_API_KEY\",
  \"ANTHROPIC_API_KEY\",
]
set = {}
include_only = []
experimental_use_profile = false

[history]
persistence = \"none\"

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


def read_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def validate_toml(label: str, text: str) -> dict:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        die(f"{label} is not valid TOML: {e}")


config_text = read_text(CONFIG)
config_data = validate_toml(str(CONFIG), config_text or "")
profile = config_data.get("profile")
if profile is not None and not isinstance(profile, str):
    die(f"{CONFIG}: root key 'profile' exists but is not a string")

n_begin = config_text.count(ROOT_BEGIN)
n_end = config_text.count(ROOT_END)
if n_begin != n_end:
    die(f"{CONFIG}: managed profile-selection markers are unbalanced ({n_begin} begin, {n_end} end)")
if n_begin > 1:
    die(f"{CONFIG}: more than one managed profile-selection block exists")

if n_begin == 1:
    start = config_text.index(ROOT_BEGIN)
    end = config_text.index(ROOT_END) + len(ROOT_END)
    existing_block = config_text[start:end]
    expected_no_final_lf = ROOT_BLOCK.rstrip("\n")
    if existing_block != expected_no_final_lf:
        die(f"{CONFIG}: existing managed profile-selection block differs from installer expectation; refusing to overwrite")
    if profile != PROFILE_NAME:
        die(f"{CONFIG}: managed block exists but parsed root profile is {profile!r}, expected {PROFILE_NAME!r}; file may be malformed")
    print(f"[info] {CONFIG}: managed profile-selection block already present")
elif profile is None:
    print(f"[info] {CONFIG}: prepending managed root profile-selection block")
    atomic_write(CONFIG, ROOT_BLOCK + ("\n" if config_text and not config_text.startswith("\n") else "") + config_text)
elif profile == PROFILE_NAME:
    print(f"[info] {CONFIG}: already selects profile {PROFILE_NAME!r} outside installer block — leaving user-owned selection alone")
else:
    die(
        f"{CONFIG}: root profile is {profile!r}, not {PROFILE_NAME!r}. "
        "Refusing to replace a user's active Codex profile. Remove or change the root profile by hand, then re-run."
    )

for path, content in [
    (SAFE_PROFILE, SAFE_CONTENT),
    (WORKSPACE_PROFILE, WORKSPACE_CONTENT),
    (DANGER_PROFILE, DANGER_CONTENT),
]:
    validate_toml(str(path), content)
    if path.exists():
        if not path.is_file():
            die(f"{path} exists but is not a regular file")
        if read_text(path) == content:
            print(f"[info] {path}: already present and matches expected bytes")
        else:
            die(f"{path}: exists with different content; refusing to overwrite user/stale profile")
    else:
        atomic_write(path, content)
        print(f"[info] {path}: created")

# Re-parse final config after possible prepend.
validate_toml(str(CONFIG), read_text(CONFIG) or "")
print("[info] Codex profile TOML validation passed")
PYEOF

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------

section "success — Codex CLI installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so PATH updates take effect."
info "Run 'codex' and verify active state with /status."
info "Default profile: personal-server-safe (read-only)."
info "Editable profile: codex --profile personal-server-workspace"
info "Container-only profile: codex --profile personal-server-container-danger"
