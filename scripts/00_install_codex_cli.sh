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
# instead of creating profiles, pins the model to gpt-5.6-sol, and installs one
# exact Codex CLI release.
#
# WHAT IT DOES (idempotently)
# ---------------------------
#   (a) Install/upgrade Codex CLI with OpenAI's documented standalone installer at
#       https://chatgpt.com/codex/install.sh, expecting ~/.local/bin/codex.
#       The release is pinned in scripts/lib/versions.sh and passed with
#       --release. The installer is invoked with CODEX_NON_INTERACTIVE=1. If
#       another codex earlier/on PATH is not that binary, this script refuses.
#   (b) Ensure one exact ~/.bashrc PATH snippet for ~/.local/bin, refusing
#       duplicate or upstream Codex PATH blocks.
#   (c) Accept only explicit known config/cache/release-tree states, migrate
#       those to the exact gpt-5.6-sol state, prune old Codex release/cache
#       leftovers, then verify the final state. Any other state refuses.
#   (d) Refuse while stale Codex processes from an old standalone or npm install
#       are still running, because they can recreate old model-cache state.
#
# IDEMPOTENCY
# -----------
# Already on the pinned release -> upstream no-op; known old state -> exact
# migration; unknown drift -> refuse before managed state writes. This script
# never touches Codex auth, sessions, logs, plugins, MCP servers, goals, memory,
# shell snapshots, or other accumulated state outside the managed config, model
# cache, standalone release tree, and exact PATH block.
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
load_versions

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
MODEL_CACHE="$CODEX_HOME_DIR/models_cache.json"
STANDALONE_ROOT="$CODEX_HOME_DIR/packages/standalone"
RELEASES_DIR="$STANDALONE_ROOT/releases"
STANDALONE_CURRENT="$STANDALONE_ROOT/current"
CODEX_BIN_TARGET="$STANDALONE_CURRENT/bin/codex"
INSTALLER_URL="https://chatgpt.com/codex/install.sh"

# ---------------------------------------------------------------------------
# Codex state validation and exact-state enforcement.
# ---------------------------------------------------------------------------

codex_state_guard() {
    local phase="$1"

    export C_PHASE="$phase"
    export C_BASHRC="$BASHRC"
    export C_CONFIG="$CONFIG"
    export C_MODEL_CACHE="$MODEL_CACHE"
    export C_CODEX_BIN="$CODEX_BIN"
    export C_CODEX_BIN_TARGET="$CODEX_BIN_TARGET"
    export C_STANDALONE_CURRENT="$STANDALONE_CURRENT"
    export C_RELEASES_DIR="$RELEASES_DIR"
    export C_CODEX_CLI_VERSION="$CODEX_CLI_VERSION"
    python3 - <<'PYEOF'
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import tomllib

PHASE = os.environ["C_PHASE"]
BASHRC = pathlib.Path(os.environ["C_BASHRC"])
CONFIG = pathlib.Path(os.environ["C_CONFIG"])
MODEL_CACHE = pathlib.Path(os.environ["C_MODEL_CACHE"])
CODEX_BIN = pathlib.Path(os.environ["C_CODEX_BIN"])
CODEX_BIN_TARGET = pathlib.Path(os.environ["C_CODEX_BIN_TARGET"])
STANDALONE_CURRENT = pathlib.Path(os.environ["C_STANDALONE_CURRENT"])
RELEASES_DIR = pathlib.Path(os.environ["C_RELEASES_DIR"])
CODEX_CLI_VERSION = os.environ["C_CODEX_CLI_VERSION"]

# Upstream names each release directory "<version>-<vendor_target>"
# (install.sh: release_name="$resolved_version-$vendor_target"). Its Linux
# vendor targets are x86_64-unknown-linux-musl and aarch64-unknown-linux-musl,
# selected from uname -m. Derive the same value rather than hardcoding x86_64,
# which silently mismatched on any non-x86_64 host.
_ARCH = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "arm64": "aarch64",
    "aarch64": "aarch64",
}.get(os.uname().machine)
if _ARCH is None:
    print(
        f"[fatal] unsupported architecture {os.uname().machine!r}; upstream install.sh "
        "supports x86_64 and aarch64 only",
        file=sys.stderr,
    )
    sys.exit(2)
VENDOR_TARGET = f"{_ARCH}-unknown-linux-musl"
PINNED_RELEASE_DIR = f"{CODEX_CLI_VERSION}-{VENDOR_TARGET}"

# Executable names upstream places in ~/.local/bin: install.sh links
# codex-code-mode-host alongside codex when the release ships it.
CODEX_BINARY_NAMES = ("codex", "codex.js", "codex-code-mode-host")

# Any release directory that is not the pinned one is prunable. The upstream
# installer self-updates (and can be run by hand), so old releases accumulate;
# hardcoding one legacy version meant the next self-update hard-refused. Entries
# must still LOOK like a release directory - anything else is drift and refuses
# rather than being deleted.
RELEASE_DIR_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z_.-]+$")

# Markers of a Codex installed outside this script's managed standalone tree.
FOREIGN_CODEX_MARKERS = (
    "/usr/local/lib/node_modules/@openai/codex",
    "/usr/local/bin/codex",
)

# Exact host config hash and old cache catalog shape from the previous
# installer-owned state. These are one-time migration inputs, not generic
# fallbacks.
OLD_LOCAL_CONFIG_SHA256 = "9846f898be46d8bdaeb33b4012cd6f54a53a0aafd939befcc7121384d5d4aa19"
OLD_MODELS_CACHE_SLUGS = {
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex-spark",
    "codex-auto-review",
}

PATH_BLOCK = (
    "\n"
    "# Added by 00_install_codex_cli.sh - codex lives in ~/.local/bin\n"
    'export PATH="$HOME/.local/bin:$PATH"\n'
)
UPSTREAM_PATH_BEGIN = "# >>> Codex installer >>>"
UPSTREAM_PATH_END = "# <<< Codex installer <<<"

NEW_MANAGED_CONFIG = """# Managed by scripts/00_install_codex_cli.sh.
# This file is intentionally direct root Codex config, not a profile. Do not edit
# by hand; edit the installer, then re-run.
#
# Automation policy:
# - Pin model/reasoning to avoid alias/catalog/default drift. Default spawned
#   sub-agents inherit this effective model/reasoning unless a non-default role
#   or explicit spawn override intentionally replaces it.
# - Match the user's preferred no-permission-prompt workflow with
#   approval_policy="never" and sandbox_mode="danger-full-access".
# - Keep web search live for agent-side research when Codex supports it.
# - Harden child-process environment inheritance enough to avoid common secret
#   leakage while preserving core shell usability.
# - Disable prompt history persistence, analytics, feedback, and startup update
#   checks on this personal infrastructure workstation.

model = "gpt-5.6-sol"
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

OLD_MANAGED_CONFIG = """# Managed by scripts/00_install_codex_cli.sh.
# This file is intentionally direct root Codex config, not a profile. Do not edit
# by hand; edit the installer, delete this exact file, then re-run.
#
# Automation policy:
# - Pin model/reasoning to avoid alias/catalog/default drift. Default spawned
#   sub-agents inherit this effective model/reasoning unless a non-default role
#   or explicit spawn override intentionally replaces it.
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


def file_sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def path_exists(path: pathlib.Path) -> bool:
    return path.exists() or path.is_symlink()


def release_dir_names() -> list[str]:
    if not path_exists(RELEASES_DIR):
        return []
    if not RELEASES_DIR.is_dir():
        die(f"{RELEASES_DIR} exists but is not a directory")
    return sorted(p.name for p in RELEASES_DIR.iterdir())


def collect_slugs(value: object) -> set[str]:
    slugs: set[str] = set()
    if isinstance(value, dict):
        slug = value.get("slug")
        if isinstance(slug, str):
            slugs.add(slug)
        for child in value.values():
            slugs.update(collect_slugs(child))
    elif isinstance(value, list):
        for child in value:
            slugs.update(collect_slugs(child))
    return slugs


def self_and_ancestor_pids() -> set[int]:
    """PIDs of this process and every ancestor.

    This script is named 00_install_codex_cli.sh, so its own command line - and
    that of the shell which launched it - contains the substring "codex".
    Without this exclusion the guard reports itself and the install can never
    get past preflight on any machine.
    """
    pids: set[int] = set()
    pid = os.getpid()
    while pid > 0 and pid not in pids:
        pids.add(pid)
        try:
            stat = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
            # Fields after the final ')' are: state, ppid, ... The comm field
            # can itself contain spaces and parens, so split after rindex(')').
            pid = int(stat[stat.rindex(")") + 1:].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return pids


def running_codex_process_problems() -> list[str]:
    problems: list[str] = []
    proc = pathlib.Path("/proc")
    if not proc.is_dir():
        return problems

    skip = self_and_ancestor_pids()

    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid in skip:
            continue
        try:
            cmdline_raw = (entry / "cmdline").read_bytes()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        argv = [a for a in cmdline_raw.decode("utf-8", "replace").split("\0") if a]
        if not argv:
            continue
        try:
            exe = os.readlink(entry / "exe")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            exe = ""

        # Identify Codex by the binary actually being executed, not by any
        # substring of the whole command line: a script path like
        # 00_install_codex_cli.sh, an editor with that file open, or a ~/codex/
        # working directory all contain "codex" without being Codex.
        candidates = [exe] + argv
        if not any(
            os.path.basename(c) in CODEX_BINARY_NAMES or "@openai/codex" in c
            for c in candidates
        ):
            continue

        combined = " ".join(candidates)
        if PINNED_RELEASE_DIR in combined:
            continue  # a process from the pinned release is the managed one
        if any(marker in combined for marker in FOREIGN_CODEX_MARKERS):
            problems.append(f"running Codex from an unmanaged system install pid={pid}: {combined}")
        else:
            problems.append(f"running non-pinned Codex process pid={pid}: {combined}")

    return problems


def model_cache_state(problems: list[str]) -> str:
    if not path_exists(MODEL_CACHE):
        return "absent"
    if MODEL_CACHE.is_symlink() or not MODEL_CACHE.is_file():
        problems.append(f"{MODEL_CACHE}: expected absent or regular file")
        return "bad"
    try:
        data = json.loads(MODEL_CACHE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        problems.append(f"{MODEL_CACHE}: invalid JSON: {e}")
        return "bad"
    slugs = collect_slugs(data)
    if (
        isinstance(data, dict)
        and set(data) == {"client_version", "etag", "fetched_at", "models"}
        and data.get("client_version") == "0.142.2"
        and isinstance(data.get("models"), list)
        and len(data["models"]) == 5
        and slugs == OLD_MODELS_CACHE_SLUGS
    ):
        return "old-known-stale"
    if "gpt-5.5" in slugs:
        problems.append(
            f"{MODEL_CACHE}: contains stale gpt-5.5 but does not match the known old 0.142.2 cache shape"
        )
        return "bad"
    return "current-or-non-stale"


def config_state(problems: list[str]) -> str:
    if not path_exists(CONFIG):
        return "absent"
    if CONFIG.is_symlink() or not CONFIG.is_file():
        problems.append(f"{CONFIG}: expected absent or regular file")
        return "bad"
    text = CONFIG.read_text(encoding="utf-8")
    if text == NEW_MANAGED_CONFIG:
        return "new-managed"
    if text == OLD_MANAGED_CONFIG:
        return "old-managed"
    if file_sha256(CONFIG) == OLD_LOCAL_CONFIG_SHA256:
        return "old-local-runtime-state"
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        problems.append(f"{CONFIG}: unexpected content and invalid TOML: {e}")
    else:
        problems.append(f"{CONFIG}: unexpected TOML content; refusing to merge or overwrite")
    return "bad"


def validate_common(allow_missing_binary: bool) -> dict[str, str]:
    problems: list[str] = []

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", CODEX_CLI_VERSION):
        problems.append(f"CODEX_CLI_VERSION must be an exact x.y.z release, got {CODEX_CLI_VERSION!r}")

    try:
        tomllib.loads(NEW_MANAGED_CONFIG)
        tomllib.loads(OLD_MANAGED_CONFIG)
    except tomllib.TOMLDecodeError as e:
        problems.append(f"internal managed Codex config TOML is invalid: {e}")

    bashrc_text = BASHRC.read_text(encoding="utf-8")
    path_block_count = bashrc_text.count(PATH_BLOCK)
    if path_block_count > 1:
        problems.append(f"{BASHRC}: exact Codex PATH block appears {path_block_count} times; expected 0 or 1")
    if UPSTREAM_PATH_BEGIN in bashrc_text or UPSTREAM_PATH_END in bashrc_text:
        problems.append(f"{BASHRC}: contains upstream Codex installer PATH block; remove it before using this managed installer")

    config = config_state(problems)
    cache = model_cache_state(problems)

    if PHASE == "preflight":
        problems.extend(running_codex_process_problems())

    if path_exists(CODEX_BIN):
        if not CODEX_BIN.is_symlink():
            problems.append(f"{CODEX_BIN}: expected symlink to {CODEX_BIN_TARGET}")
        elif os.readlink(CODEX_BIN) != str(CODEX_BIN_TARGET):
            problems.append(f"{CODEX_BIN}: symlink target is {os.readlink(CODEX_BIN)!r}, expected {str(CODEX_BIN_TARGET)!r}")
    elif not allow_missing_binary:
        problems.append(f"{CODEX_BIN}: missing after installer")

    # Non-pinned releases are tolerated here and pruned in commit(); the final
    # verification below enforces that exactly the pinned release survives.
    for name in release_dir_names():
        if not RELEASE_DIR_RE.fullmatch(name):
            problems.append(f"{RELEASES_DIR}: unexpected entry {name!r} (not a release directory)")

    if path_exists(STANDALONE_CURRENT):
        if not STANDALONE_CURRENT.is_symlink():
            problems.append(f"{STANDALONE_CURRENT}: expected symlink")
        else:
            current_target = pathlib.Path(os.readlink(STANDALONE_CURRENT)).name
            if not RELEASE_DIR_RE.fullmatch(current_target):
                problems.append(
                    f"{STANDALONE_CURRENT}: points at {current_target!r}, which is not a release directory"
                )
    elif not allow_missing_binary:
        problems.append(f"{STANDALONE_CURRENT}: missing after installer")

    if problems:
        print(f"[fatal] Codex {PHASE} refused; no managed state changes were made in this phase.", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        sys.exit(2)

    return {
        "config": config,
        "cache": cache,
        "path_block_count": str(path_block_count),
    }


def commit() -> None:
    state = validate_common(allow_missing_binary=False)

    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    if state["config"] == "new-managed":
        print(f"[info] {CONFIG}: already exact managed gpt-5.6-sol config")
    else:
        print(f"[info] {CONFIG}: replacing {state['config']} with exact managed gpt-5.6-sol config")
        atomic_write(CONFIG, NEW_MANAGED_CONFIG)

    if state["cache"] == "old-known-stale":
        MODEL_CACHE.unlink()
        print(f"[info] {MODEL_CACHE}: deleted exact old gpt-5.5 model cache")

    if state["path_block_count"] == "0":
        text = BASHRC.read_text(encoding="utf-8")
        atomic_write(BASHRC, text + PATH_BLOCK)
        print(f"[info] {BASHRC}: appended exact Codex PATH block")
    else:
        print(f"[info] {BASHRC}: exact Codex PATH block already present")

    if path_exists(RELEASES_DIR):
        for child in RELEASES_DIR.iterdir():
            if child.name == PINNED_RELEASE_DIR:
                continue
            if not RELEASE_DIR_RE.fullmatch(child.name):
                die(f"{RELEASES_DIR}: unexpected entry appeared during install: {child.name!r}")
            shutil.rmtree(child)
            print(f"[info] {child}: pruned non-pinned standalone release")

    final_problems: list[str] = []
    if config_state(final_problems) != "new-managed":
        final_problems.append(f"{CONFIG}: final config is not exact managed gpt-5.6-sol config")
    if BASHRC.read_text(encoding="utf-8").count(PATH_BLOCK) != 1:
        final_problems.append(f"{BASHRC}: final exact Codex PATH block count is not 1")
    final_cache = model_cache_state(final_problems)
    if final_cache == "old-known-stale":
        final_problems.append(f"{MODEL_CACHE}: final old model cache still exists")
    if sorted(release_dir_names()) != [PINNED_RELEASE_DIR]:
        final_problems.append(f"{RELEASES_DIR}: final release set is {release_dir_names()!r}, expected {[PINNED_RELEASE_DIR]!r}")
    if not path_exists(STANDALONE_CURRENT) or not STANDALONE_CURRENT.is_symlink():
        final_problems.append(f"{STANDALONE_CURRENT}: final current link missing or not a symlink")
    elif pathlib.Path(os.readlink(STANDALONE_CURRENT)).name != PINNED_RELEASE_DIR:
        final_problems.append(f"{STANDALONE_CURRENT}: final current link does not point at {PINNED_RELEASE_DIR}")
    if final_problems:
        print("[fatal] Codex final verification failed.", file=sys.stderr)
        for problem in final_problems:
            print(f"  - {problem}", file=sys.stderr)
        sys.exit(2)

    print("[info] final Codex managed-state verification passed")


if PHASE == "preflight":
    state = validate_common(allow_missing_binary=True)
    print(f"[info] preflight config state: {state['config']}")
    print(f"[info] preflight model cache state: {state['cache']}")
elif PHASE == "commit":
    commit()
else:
    die(f"unknown phase {PHASE!r}")
PYEOF
}

# ---------------------------------------------------------------------------
# (a) preflight, install Codex CLI, then enforce exact local state
# ---------------------------------------------------------------------------

section "(a) preflight exact Codex state"

if command -v codex >/dev/null 2>&1; then
    FOUND_CODEX="$(command -v codex)"
    if [ "$FOUND_CODEX" != "$CODEX_BIN" ]; then
        die "found codex at '$FOUND_CODEX', but this installer manages '$CODEX_BIN'. Refusing to shadow or replace a different Codex install."
    fi
fi

codex_state_guard preflight

section "(b) install Codex CLI $CODEX_CLI_VERSION via $INSTALLER_URL"

# The PATH="$LOCAL_BIN:$PATH" prefix is load-bearing, not cosmetic. Upstream
# add_to_path() returns early when $BIN_DIR is already on PATH; otherwise it
# appends its own "# >>> Codex installer >>>" block to a shell profile - which
# the commit-phase validator below then refuses as unmanaged drift. Putting
# ~/.local/bin on PATH for the installer keeps it from writing that block.
# (Upstream still writes it if it detects a brew/npm-managed codex; that is a
# genuine conflict and refusing is correct.)
# CODEX_NON_INTERACTIVE=1 is honoured: install.sh accepts 1, true, or yes.
info "running upstream installer for exact release $CODEX_CLI_VERSION"
curl -fsSL "$INSTALLER_URL" \
    | PATH="$LOCAL_BIN:$PATH" CODEX_NON_INTERACTIVE=1 sh -s -- --release "$CODEX_CLI_VERSION"
[ -x "$CODEX_BIN" ] \
    || die "after running installer, $CODEX_BIN does not exist or is not executable - installer must have failed"

VER_LINE="$("$CODEX_BIN" --version 2>&1 | head -1 || true)"
[ -n "$VER_LINE" ] || die "'$CODEX_BIN --version' produced no output"
case "$VER_LINE" in
    *" $CODEX_CLI_VERSION") ;;
    *) die "expected '$CODEX_BIN --version' to end with '$CODEX_CLI_VERSION', got: $VER_LINE" ;;
esac
info "codex --version: $VER_LINE"

section "(c) enforce exact Codex config, PATH, cache, and release tree"

codex_state_guard commit

section "success - Codex CLI installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so PATH updates take effect."
info "Run 'codex' and verify active state with /status."
info "Pinned Codex CLI release: $CODEX_CLI_VERSION."
info "Managed default: model=gpt-5.6-sol, approval_policy=never, sandbox_mode=danger-full-access."
