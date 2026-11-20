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
# instead of creating profiles, pins the model to gpt-6.2-sol, and installs one
# exact Codex CLI release. The same release is also put on Codex's own local
# app-server daemon, which is a second, separately versioned package.
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
#       those to the exact gpt-6.2-sol state, prune old Codex release/cache
#       leftovers, then verify the final state. Any other state refuses.
#       "Exact" means the managed block is byte-exact; the tables Codex itself
#       appends while running ([projects.*] trust levels, [tui.*], [notice],
#       [mcp_servers.*]) are recognised and preserved verbatim, never rewritten.
#   (d) Refuse while stale host Codex processes from an old standalone or npm
#       install are still running, because they can recreate old model-cache
#       state. Processes in descendant/container PID namespaces are ignored
#       before command-line reconnaissance; this script never signals processes.
#       The one exception is Codex's own managed app-server daemon and its
#       pid-update-loop, run from ~/.codex/packages/app-server-daemon/releases/
#       <release>/bin/: step (e) brings them to the pin.
#   (e) Put Codex's local app-server daemon (the process the VS Code Codex
#       extension talks to; ~/.codex/packages/app-server-daemon) on the same
#       exact release, when that package exists. The upstream standalone
#       installer never touches it, so it had stayed on 0.159.0 beside a 0.170.0
#       CLI, and that old daemon could not serve gpt-6.2-sol on a ChatGPT
#       sign-in. This script runs Codex's own `codex app-server daemon update
#       --from-cli --yes` ("Copy and pin this CLI package"): the pinned CLI's own
#       package becomes the daemon's release and is pinned against Codex's
#       automatic updates (plain `daemon update` ignores CODEX_RELEASE and
#       installs "latest", so it cannot hold a pin). It then verifies with
#       `codex app-server daemon version`, prunes every other daemon release
#       directory once no process runs from it, and verifies that the final
#       daemon release set is exactly the pinned release. A daemon NEWER than
#       the pin is refused, never downgraded: bump CODEX_CLI_VERSION first.
#
# IDEMPOTENCY
# -----------
# Already on the pinned release -> upstream no-op; known old state -> exact
# migration; unknown drift -> refuse before managed state writes. This script
# never touches Codex auth, sessions, logs, plugins, MCP servers, goals, memory,
# shell snapshots, the daemon's runtime state (~/.codex/app-server-daemon and
# ~/.codex/app-server-control), or other accumulated state outside the managed
# config, model cache, standalone release tree, app-server daemon package tree
# (~/.codex/packages/app-server-daemon), and exact PATH block. The only thing
# done to the running daemon is Codex's own `daemon update --from-cli` command,
# which restarts it; work running in the daemon is interrupted after Codex's
# own shutdown grace, so run this when the daemon is idle.
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
DAEMON_ROOT="$CODEX_HOME_DIR/packages/app-server-daemon"
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
    export C_DAEMON_ROOT="$DAEMON_ROOT"
    export C_CODEX_CLI_VERSION="$CODEX_CLI_VERSION"
    export C_SCRIPT_DIR="$SCRIPT_DIR"
    python3 - <<'PYEOF'
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

SCRIPT_DIR = pathlib.Path(os.environ["C_SCRIPT_DIR"])
sys.path.insert(0, str(SCRIPT_DIR))

from lib.host_processes import HostProcessScopeError, host_process_dirs

PHASE = os.environ["C_PHASE"]
BASHRC = pathlib.Path(os.environ["C_BASHRC"])
CONFIG = pathlib.Path(os.environ["C_CONFIG"])
MODEL_CACHE = pathlib.Path(os.environ["C_MODEL_CACHE"])
CODEX_BIN = pathlib.Path(os.environ["C_CODEX_BIN"])
CODEX_BIN_TARGET = pathlib.Path(os.environ["C_CODEX_BIN_TARGET"])
STANDALONE_CURRENT = pathlib.Path(os.environ["C_STANDALONE_CURRENT"])
RELEASES_DIR = pathlib.Path(os.environ["C_RELEASES_DIR"])
DAEMON_ROOT = pathlib.Path(os.environ["C_DAEMON_ROOT"])
CODEX_CLI_VERSION = os.environ["C_CODEX_CLI_VERSION"]
PROC = pathlib.Path("/proc")

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
STABLE_RELEASE_RE = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)-" + re.escape(VENDOR_TARGET) + r"$")

# Codex's own local app-server daemon (the process the VS Code Codex extension
# talks to) is a SECOND, separately versioned package tree. The upstream
# standalone installer never touches it, so it stays on whatever release Codex
# last put there (0.159.0 for months beside a 0.170.0 CLI). Layout, from the
# upstream install.sh (CODEX_INSTALL_DAEMON_ONLY=1 selects this root) and from a
# real tree: releases/<version>-<target>, a `current` symlink, selection-history,
# install.lock, and auto-update-version. The last file is the auto-update switch:
# install.sh writes it after a `latest` install and removes it after any pinned
# install, and a scheduled update exits unless it names the selected release.
# `codex app-server daemon update --from-cli --yes` ("Copy and pin this CLI
# package") copies the running CLI's own package into this tree and pins it
# against automatic updates; plain `daemon update` ignores CODEX_RELEASE and
# installs "latest". Any other entry in the tree is drift and refuses.
DAEMON_RELEASES_DIR = DAEMON_ROOT / "releases"
DAEMON_CURRENT = DAEMON_ROOT / "current"
DAEMON_AUTO_UPDATE_VERSION = DAEMON_ROOT / "auto-update-version"
DAEMON_ROOT_ENTRIES = frozenset(
    {"auto-update-version", "current", "install.lock", "releases", "selection-history"}
)

# Helper programs Codex's daemon starts from its own release directory.
DAEMON_HELPER_BINARIES = ("codex-code-mode-host", "codex-exec-server")

# Environment names Codex's own updater reads when it runs the upstream
# installer. None may leak from the caller into `codex app-server daemon ...`.
DAEMON_COMMAND_ENV_SCRUBBED = (
    "CODEX_RELEASE",
    "CODEX_NON_INTERACTIVE",
    "CODEX_INSTALL_DAEMON_ONLY",
    "CODEX_INSTALL_DEFER_SELECTION",
    "CODEX_INSTALL_IF_CURRENT",
    "CODEX_INSTALL_IF_LATEST",
    "CODEX_UPDATE_FROM_RELEASE",
)

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

# Exact host config hash from the previous installer-owned state. A one-time
# migration input, not a generic fallback.
OLD_LOCAL_CONFIG_SHA256 = "9846f898be46d8bdaeb33b4012cd6f54a53a0aafd939befcc7121384d5d4aa19"

# Fingerprints of preceding installer-managed configs. Exact length and digest
# permit migrations with Codex-owned runtime tables without retaining obsolete
# model selections or accepting arbitrary user edits.
PREVIOUS_MANAGED_CONFIG_FINGERPRINTS = (
    (1625, "e52bb850edea508898d73e36430aa11274c05ac1d65f1b1ac8118732d7e01b56"),
    (1625, "3ca37b4fcf5adbf8e3185645ee601eac0b899c15376d1afcf5c8b0bbd7d6d6b6"),
    (1623, "1765d5ca4ecafc83a58a522fa0e8497723d6d6aa6a8994a2f78c70d3ef43aeb4"),
)

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

model = "gpt-6.2-sol"
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


def self_and_ancestor_pids(proc: pathlib.Path) -> set[int]:
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
            stat = (proc / str(pid) / "stat").read_text(encoding="utf-8", errors="replace")
            # Fields after the final ')' are: state, ppid, ... The comm field
            # can itself contain spaces and parens, so split after rindex(')').
            pid = int(stat[stat.rindex(")") + 1:].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return pids


def might_be_codex(entry: pathlib.Path) -> bool:
    """For a caller-owned process whose PID namespace cannot be read: whether its
    command line could be Codex. An unreadable command line counts as could."""
    try:
        raw = (entry / "cmdline").read_bytes()
    except (FileNotFoundError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    argv = [a for a in raw.decode("utf-8", "replace").split("\0") if a]
    if not argv:
        return False
    candidates = [argv[0]]
    if os.path.basename(argv[0]) in ("node", "nodejs") and len(argv) > 1:
        candidates.append(argv[1])
    return any(os.path.basename(c) in CODEX_BINARY_NAMES or "@openai/codex" in c for c in candidates)


def running_codex_process_problems() -> list[str]:
    problems: list[str] = []
    proc = PROC
    try:
        entries = host_process_dirs(proc, relevant=might_be_codex)
    except HostProcessScopeError as error:
        return [f"cannot scope Codex process scan to the host: {error}"]

    skip = self_and_ancestor_pids(proc)

    # host_process_dirs() performs the PID-namespace check before this loop, so
    # no command line or executable from a container is used for reconnaissance
    # or can become a target of any future process cleanup added here.
    for entry in entries:
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

        # Identify Codex by its executable or a Node launcher script. Other
        # arguments can mention Codex without running it (for example, a tmux
        # session name or a shell command that invokes this installer).
        candidates = [exe, argv[0]]
        if os.path.basename(exe) in ("node", "nodejs") and len(argv) > 1:
            candidates.append(argv[1])
        if not any(
            os.path.basename(c) in CODEX_BINARY_NAMES or "@openai/codex" in c
            for c in candidates
        ):
            continue

        combined = " ".join([exe] + argv)
        if PINNED_RELEASE_DIR in combined:
            continue  # a process from the pinned release is the managed one
        if daemon_role(exe, argv) is not None:
            continue  # Codex's own managed daemon; commit() brings it to the pin
        if any(marker in combined for marker in FOREIGN_CODEX_MARKERS):
            problems.append(f"running host Codex from an unmanaged system install pid={pid}: {combined}")
        else:
            problems.append(f"running non-pinned host Codex process pid={pid}: {combined}")

    return problems


def refuse(title: str, problems: list[str]) -> None:
    print(f"[fatal] {title}", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    sys.exit(2)


def release_version(name: str) -> tuple[int, int, int] | None:
    """x.y.z of a stable release directory name for this platform, else None."""
    match = STABLE_RELEASE_RE.fullmatch(name)
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def pinned_version() -> tuple[int, int, int] | None:
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", CODEX_CLI_VERSION)
    if match is None:
        return None  # validate_common() reports the malformed pin
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def daemon_exe_parts(exe: str) -> tuple[str, str] | None:
    """(release directory, binary name) when `exe` is
    <daemon releases>/<release>/bin/<binary>, else None."""
    for root in {str(DAEMON_RELEASES_DIR), os.path.realpath(DAEMON_RELEASES_DIR)}:
        prefix = root + "/"
        if exe.startswith(prefix):
            parts = exe[len(prefix):].split("/")
            if len(parts) == 3 and RELEASE_DIR_RE.fullmatch(parts[0]) and parts[1] == "bin":
                return parts[0], parts[2]
    return None


def daemon_role(exe: str, argv: list[str]) -> str | None:
    """"daemon", "updater" or "helper" for a process that is part of Codex's own
    managed app-server daemon, else None. Exact argv shapes only: a hand-run
    `codex exec` from an old daemon release is still a stale host Codex."""
    parts = daemon_exe_parts(exe)
    if parts is None:
        return None
    binary = parts[1]
    if binary == "codex":
        if argv[1:] == ["app-server", "daemon", "pid-update-loop"]:
            return "updater"
        if argv[1:2] == ["app-server"] and "--managed-daemon" in argv[2:]:
            return "daemon"
        return None
    if binary in DAEMON_HELPER_BINARIES:
        return "helper"
    return None


def host_process_table() -> list[tuple[int, str, list[str]]]:
    """(pid, executable, argv) for every process in the host's own PID namespace,
    this installer and its ancestors excluded. Container processes are out of
    scope exactly as in running_codex_process_problems(). An unreadable
    executable or command line is reported as empty."""
    try:
        entries = host_process_dirs(PROC, relevant=might_be_codex)
    except HostProcessScopeError as error:
        die(f"cannot scope the Codex process scan to the host: {error}")
    skip = self_and_ancestor_pids(PROC)
    table: list[tuple[int, str, list[str]]] = []
    for entry in entries:
        pid = int(entry.name)
        if pid in skip:
            continue
        try:
            raw = (entry / "cmdline").read_bytes()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            raw = b""
        argv = [a for a in raw.decode("utf-8", "replace").split("\0") if a]
        try:
            exe = os.readlink(entry / "exe")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            exe = ""
        table.append((pid, exe, argv))
    return table


def managed_daemon_processes() -> list[tuple[int, str, str, str]]:
    """(pid, role, release directory, executable) of Codex's managed daemon."""
    found: list[tuple[int, str, str, str]] = []
    for pid, exe, argv in host_process_table():
        role = daemon_role(exe, argv)
        parts = daemon_exe_parts(exe)
        if role is not None and parts is not None:
            found.append((pid, role, parts[0], exe))
    return found


def processes_using(directory: pathlib.Path) -> tuple[list[str], list[str]]:
    """(running from `directory`, Codex-like but unverifiable) over host processes."""
    roots = {str(directory), os.path.realpath(directory)}
    using: list[str] = []
    unverifiable: list[str] = []
    for pid, exe, argv in host_process_table():
        names = [name for name in (exe, argv[0] if argv else "") if name]
        if any(name == root or name.startswith(root + "/") for name in names for root in roots):
            using.append(f"pid={pid} {' '.join([exe] + argv)}")
        elif not exe and argv and os.path.basename(argv[0]) in CODEX_BINARY_NAMES + ("rg", "bwrap") + DAEMON_HELPER_BINARIES:
            unverifiable.append(f"pid={pid} {' '.join(argv)}")
    return using, unverifiable


def daemon_package_state(problems: list[str]) -> dict:
    """Validate the daemon package tree and describe it: present, the selected
    release directory name, and whether Codex's scheduled updater still follows
    the latest channel (auto-update-version names the selected release)."""
    state: dict = {"present": False, "selected": None, "following_latest": False}
    if not path_exists(DAEMON_ROOT):
        return state
    state["present"] = True
    if DAEMON_ROOT.is_symlink() or not DAEMON_ROOT.is_dir():
        problems.append(f"{DAEMON_ROOT}: expected a real directory")
        return state
    for child in sorted(DAEMON_ROOT.iterdir()):
        if child.name not in DAEMON_ROOT_ENTRIES:
            problems.append(
                f"{DAEMON_ROOT}: unexpected entry {child.name!r} (an interrupted Codex daemon "
                "install, or a layout this installer does not know)"
            )
    for name in ("install.lock", "selection-history", "auto-update-version"):
        file_path = DAEMON_ROOT / name
        if path_exists(file_path) and (file_path.is_symlink() or not file_path.is_file()):
            problems.append(f"{file_path}: expected a regular file")
    if not path_exists(DAEMON_RELEASES_DIR):
        problems.append(f"{DAEMON_RELEASES_DIR}: missing")
    elif DAEMON_RELEASES_DIR.is_symlink() or not DAEMON_RELEASES_DIR.is_dir():
        problems.append(f"{DAEMON_RELEASES_DIR}: expected a real directory")
    else:
        for child in sorted(DAEMON_RELEASES_DIR.iterdir()):
            if not RELEASE_DIR_RE.fullmatch(child.name):
                problems.append(f"{DAEMON_RELEASES_DIR}: unexpected entry {child.name!r} (not a release directory)")
            elif child.is_symlink() or not child.is_dir():
                problems.append(f"{child}: expected a real release directory")
    if not path_exists(DAEMON_CURRENT):
        problems.append(f"{DAEMON_CURRENT}: no daemon release is selected")
        return state
    if not DAEMON_CURRENT.is_symlink():
        problems.append(f"{DAEMON_CURRENT}: expected symlink")
        return state
    target = pathlib.Path(os.path.realpath(DAEMON_CURRENT))
    if target.parent != pathlib.Path(os.path.realpath(DAEMON_RELEASES_DIR)) or not target.is_dir():
        problems.append(
            f"{DAEMON_CURRENT}: points at {os.readlink(DAEMON_CURRENT)!r}, "
            f"which is not a release directory under {DAEMON_RELEASES_DIR}"
        )
        return state
    selected = target.name
    version = release_version(selected)
    if version is None:
        problems.append(f"{DAEMON_CURRENT}: selected release {selected!r} is not a stable x.y.z-{VENDOR_TARGET} release")
        return state
    state["selected"] = selected
    pin = pinned_version()
    if pin is not None and version > pin:
        problems.append(
            f"{DAEMON_CURRENT}: the daemon runs release {selected}, NEWER than the pinned Codex "
            f"{CODEX_CLI_VERSION}. This installer never downgrades the daemon: test that release and "
            "bump CODEX_CLI_VERSION in scripts/lib/versions.sh, then re-run"
        )
    if path_exists(DAEMON_AUTO_UPDATE_VERSION) and DAEMON_AUTO_UPDATE_VERSION.is_file():
        recorded = DAEMON_AUTO_UPDATE_VERSION.read_text(encoding="utf-8", errors="replace").strip()
        if not RELEASE_DIR_RE.fullmatch(recorded):
            problems.append(f"{DAEMON_AUTO_UPDATE_VERSION}: unexpected content {recorded!r}")
        else:
            state["following_latest"] = recorded == selected
    return state


def daemon_summary(daemon: dict) -> str:
    if not daemon["present"]:
        return "absent"
    if daemon["selected"] == PINNED_RELEASE_DIR and not daemon["following_latest"]:
        return f"pinned to {PINNED_RELEASE_DIR}"
    latest = "follows Codex's latest channel" if daemon["following_latest"] else "pinned against auto-update"
    return f"will be brought to {PINNED_RELEASE_DIR} (selected {daemon['selected']}, {latest})"


def run_codex(args: list[str], capture: bool = False) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in DAEMON_COMMAND_ENV_SCRUBBED}
    sys.stdout.flush()
    sys.stderr.flush()
    return subprocess.run(
        [str(CODEX_BIN), *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else None,
        text=True,
        env=env,
        check=False,
    )


def daemon_package_json_problems() -> list[str]:
    manifest = DAEMON_RELEASES_DIR / PINNED_RELEASE_DIR / "codex-package.json"
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{manifest}: unreadable: {error}"]
    problems: list[str] = []
    if not isinstance(data, dict) or data.get("version") != CODEX_CLI_VERSION or data.get("target") != VENDOR_TARGET:
        problems.append(f"{manifest}: not the pinned package ({CODEX_CLI_VERSION} / {VENDOR_TARGET})")
    binary = DAEMON_RELEASES_DIR / PINNED_RELEASE_DIR / "bin" / "codex"
    if not (binary.is_file() and os.access(binary, os.X_OK)):
        problems.append(f"{binary}: missing or not executable")
    return problems


def daemon_version_problems(raw: str, daemon_running: bool) -> list[str]:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as error:
        return [f"`codex app-server daemon version` printed invalid JSON ({error}): {raw!r}"]
    if not isinstance(data, dict):
        return [f"`codex app-server daemon version` printed {raw!r}, expected a JSON object"]
    problems: list[str] = []
    if data.get("managedCodexVersion") != CODEX_CLI_VERSION:
        problems.append(f"daemon version: managedCodexVersion is {data.get('managedCodexVersion')!r}, expected {CODEX_CLI_VERSION!r}")
    running = data.get("appServerVersion")
    if running is not None and running != CODEX_CLI_VERSION:
        problems.append(f"daemon version: appServerVersion is {running!r}, expected {CODEX_CLI_VERSION!r}")
    if running is None and daemon_running:
        problems.append("a managed daemon process is running but daemon version reports no appServerVersion")
    return problems


def ensure_daemon_pinned() -> None:
    """Bring Codex's managed app-server daemon, when it exists, onto exactly the
    pinned release through Codex's own command; verify; prune the rest."""
    problems: list[str] = []
    daemon = daemon_package_state(problems)
    if problems:
        refuse("Codex app-server daemon refused; nothing was changed in the daemon tree.", problems)
    if not daemon["present"]:
        print(f"[info] {DAEMON_ROOT}: no Codex app-server daemon package; nothing to bring to the pin")
        return

    # `daemon update --from-cli` copies the CLI it is run from. Make sure that is
    # the pinned standalone release, not whatever ~/.local/bin/codex points at.
    cli = pathlib.Path(os.path.realpath(CODEX_BIN))
    pinned_cli = pathlib.Path(os.path.realpath(RELEASES_DIR / PINNED_RELEASE_DIR / "bin" / "codex"))
    if cli != pinned_cli:
        die(f"{CODEX_BIN} resolves to {cli}, expected the pinned standalone release {pinned_cli}; refusing to copy it into the daemon tree")

    off_pin = [
        f"{role} pid={pid} runs from {exe}"
        for pid, role, release, exe in managed_daemon_processes()
        if release != PINNED_RELEASE_DIR
    ]
    reasons: list[str] = []
    if daemon["selected"] != PINNED_RELEASE_DIR:
        reasons.append(f"selected release is {daemon['selected']}")
    if daemon["following_latest"]:
        reasons.append("Codex's scheduled updater still follows the latest channel (auto-update-version names the selected release)")
    reasons.extend(off_pin)

    ran_update = False
    if reasons:
        print(f"[info] {DAEMON_ROOT}: daemon must be brought to {PINNED_RELEASE_DIR}: " + "; ".join(reasons))
        print(
            "[info] running Codex's own: codex app-server daemon update --from-cli --yes "
            "(Codex restarts its daemon; work running in it is interrupted after Codex's shutdown grace)"
        )
        result = run_codex(["app-server", "daemon", "update", "--from-cli", "--yes"])
        ran_update = True
        if result.returncode != 0:
            die(
                f"`codex app-server daemon update --from-cli --yes` failed with exit {result.returncode}; "
                "the daemon tree is as Codex left it. Read Codex's message above and re-run this installer"
            )
    else:
        print(f"[info] {DAEMON_ROOT}: daemon already pinned to {PINNED_RELEASE_DIR}; leaving it alone")

    problems = []
    daemon = daemon_package_state(problems)
    if daemon["selected"] != PINNED_RELEASE_DIR:
        problems.append(
            f"{DAEMON_CURRENT}: selected daemon release is {daemon['selected']!r}, expected {PINNED_RELEASE_DIR!r}"
        )
    if daemon["following_latest"]:
        problems.append(
            f"{DAEMON_AUTO_UPDATE_VERSION}: still names the selected release, so Codex's scheduled "
            "updater still follows the latest channel and would replace the pin"
        )
    problems.extend(daemon_package_json_problems())
    procs = managed_daemon_processes()
    for pid, role, release, exe in procs:
        if release != PINNED_RELEASE_DIR:
            problems.append(
                f"managed daemon {role} pid={pid} still runs from {exe}; run `codex app-server daemon "
                "restart` when its work is idle (this installer never signals processes)"
            )
    if problems:
        refuse("Codex app-server daemon is not on the pinned release.", problems)

    daemon_running = any(role == "daemon" for _pid, role, _release, _exe in procs)
    if ran_update or daemon_running:
        result = run_codex(["app-server", "daemon", "version"], capture=True)
        if result.returncode != 0:
            refuse(
                "`codex app-server daemon version` failed.",
                [f"exit {result.returncode}, output {result.stdout!r}"],
            )
        print(f"[info] codex app-server daemon version: {' '.join(result.stdout.split())}")
        version_problems = daemon_version_problems(result.stdout, daemon_running)
        if version_problems:
            refuse("Codex app-server daemon is not on the pinned release.", version_problems)

    stale = [child for child in sorted(DAEMON_RELEASES_DIR.iterdir()) if child.name != PINNED_RELEASE_DIR]
    blockers: list[str] = []
    for child in stale:
        using, unverifiable = processes_using(child)
        blockers.extend(f"{child}: in use by {item}" for item in using)
        blockers.extend(f"{child}: cannot prove unused, Codex-like process {item}" for item in unverifiable)
    if blockers:
        refuse(
            "Refusing to prune non-pinned daemon releases that may still be running "
            "(this installer never signals processes; stop them or let them finish, then re-run).",
            blockers,
        )
    # Filesystem cleanup of exact children of the daemon's own release directory,
    # each already validated by daemon_package_state() as a real release directory.
    for child in stale:
        shutil.rmtree(child)
        print(f"[info] {child}: pruned non-pinned app-server daemon release")


def daemon_final_problems() -> list[str]:
    problems: list[str] = []
    daemon = daemon_package_state(problems)
    if not daemon["present"]:
        return problems
    names = sorted(p.name for p in DAEMON_RELEASES_DIR.iterdir()) if DAEMON_RELEASES_DIR.is_dir() else []
    if names != [PINNED_RELEASE_DIR]:
        problems.append(f"{DAEMON_RELEASES_DIR}: final daemon release set is {names!r}, expected {[PINNED_RELEASE_DIR]!r}")
    if daemon["selected"] != PINNED_RELEASE_DIR:
        problems.append(f"{DAEMON_CURRENT}: final current link does not point at {PINNED_RELEASE_DIR}")
    if daemon["following_latest"]:
        problems.append(f"{DAEMON_AUTO_UPDATE_VERSION}: final daemon still follows Codex's latest channel")
    problems.extend(daemon_package_json_problems())
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
    # Staleness is a property of the CLIENT that wrote the cache, not of any
    # model name in it. The previous rule hardcoded one 0.142.2 catalog shape
    # and additionally condemned any cache mentioning gpt-5.5 - written when
    # gpt-5.5 was the OUTGOING default. Both have rotted: gpt-5.5 is a listed
    # model in the live catalog again, so a freshly fetched, entirely correct
    # cache refused the install; and the hardcoded shape would need a new magic
    # constant at every pin bump. Keying on client_version is exact, needs no
    # maintenance, and still catches the old 0.142.2 artifact.
    if not isinstance(data, dict) or not isinstance(data.get("client_version"), str):
        problems.append(f"{MODEL_CACHE}: not a Codex model cache (no client_version string)")
        return "bad"
    if data["client_version"] != CODEX_CLI_VERSION:
        return "stale-other-version"
    return "current"


# Tables Codex itself appends to the managed config while it runs. These are
# the CLI's own state, not hand edits: it writes [projects.*] when a directory
# is trusted, [tui.*] for one-shot UI counters, [notice] for dismissed nudges,
# and [mcp_servers.*] for a server added with `codex mcp add`. Refusing them
# made this installer un-runnable on any box that had actually been used, and
# commit() would have silently deleted them (11 trust entries and an MCP server
# on the reference box). They are now preserved verbatim across a re-run.
# Anything outside this set is still drift and still refuses.
RUNTIME_TAIL_TABLES = ("projects", "tui", "mcp_servers", "notice")


def split_runtime_tail(text: str, head: str) -> str | None:
    """Return the Codex-owned tail if `text` is exactly `head` plus appended
    runtime tables, else None. The tail is parsed as a standalone TOML document
    so a bare `key = value` cannot smuggle a key into the managed block."""
    if not text.startswith(head):
        return None
    tail = text[len(head):]
    if not tail.strip():
        return ""
    try:
        parsed = tomllib.loads(tail)
    except tomllib.TOMLDecodeError:
        return None
    if not parsed or any(table not in RUNTIME_TAIL_TABLES for table in parsed):
        return None
    return tail


def split_previous_managed_tail(text: str) -> str | None:
    for length, digest in PREVIOUS_MANAGED_CONFIG_FINGERPRINTS:
        head = text[:length]
        if hashlib.sha256(head.encode("utf-8")).hexdigest() == digest:
            return split_runtime_tail(text, head)
    return None


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
    # Parse the whole document once, before the tail checks: a tail that
    # re-opens a managed table parses fine on its own but makes the full file
    # invalid TOML, and Codex would then fail to load it.
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        problems.append(f"{CONFIG}: unexpected content and invalid TOML: {e}")
        return "bad"
    if split_runtime_tail(text, NEW_MANAGED_CONFIG):
        return "new-managed+runtime"
    if split_runtime_tail(text, OLD_MANAGED_CONFIG):
        return "old-managed+runtime"
    previous_tail = split_previous_managed_tail(text)
    if previous_tail is not None:
        return "previous-managed+runtime" if previous_tail else "previous-managed"
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
    daemon = daemon_package_state(problems)

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
        "daemon": daemon_summary(daemon),
        "path_block_count": str(path_block_count),
    }


def commit() -> None:
    state = validate_common(allow_missing_binary=False)

    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    if state["config"] == "new-managed":
        print(f"[info] {CONFIG}: already exact managed gpt-6.2-sol config")
    elif state["config"] == "new-managed+runtime":
        print(
            f"[info] {CONFIG}: exact managed gpt-6.2-sol config plus Codex's own "
            "runtime tables; leaving both intact"
        )
    else:
        # Only the one validated state is allowed to contribute a tail, and it
        # must still be there on re-read. No "tail = whatever we could salvage"
        # fallback: a disagreement between validation and this read means the
        # file changed under us, which is a refusal, not something to paper over.
        tail = ""
        if state["config"] in ("old-managed+runtime", "previous-managed+runtime"):
            text = CONFIG.read_text(encoding="utf-8")
            tail = (split_runtime_tail(text, OLD_MANAGED_CONFIG)
                    if state["config"] == "old-managed+runtime"
                    else split_previous_managed_tail(text))
            if not tail:
                die(f"{CONFIG}: changed between validation and write; re-run the installer")
            print(f"[info] {CONFIG}: carrying Codex's runtime tables across the migration")
        print(f"[info] {CONFIG}: replacing {state['config']} with exact managed gpt-6.2-sol config")
        atomic_write(CONFIG, NEW_MANAGED_CONFIG + tail)

    ensure_daemon_pinned()

    # Read the cache again AFTER the daemon step: until Codex restarts it, an old
    # daemon can still write a cache stamped with its own client_version.
    cache_problems: list[str] = []
    cache_now = model_cache_state(cache_problems)
    if cache_problems:
        refuse("Codex model cache refused after the daemon step.", cache_problems)
    if cache_now == "stale-other-version":
        MODEL_CACHE.unlink()
        print(f"[info] {MODEL_CACHE}: deleted model cache written by a different Codex client")

    if state["path_block_count"] == "0":
        text = BASHRC.read_text(encoding="utf-8")
        atomic_write(BASHRC, text + PATH_BLOCK)
        print(f"[info] {BASHRC}: appended exact Codex PATH block")
    else:
        print(f"[info] {BASHRC}: exact Codex PATH block already present")

    if path_exists(RELEASES_DIR):
        # This is filesystem cleanup, not process cleanup: every candidate is an
        # exact child of the host's managed standalone release directory.
        for child in RELEASES_DIR.iterdir():
            if child.name == PINNED_RELEASE_DIR:
                continue
            if not RELEASE_DIR_RE.fullmatch(child.name):
                die(f"{RELEASES_DIR}: unexpected entry appeared during install: {child.name!r}")
            shutil.rmtree(child)
            print(f"[info] {child}: pruned non-pinned standalone release")

    final_problems: list[str] = []
    if config_state(final_problems) not in ("new-managed", "new-managed+runtime"):
        final_problems.append(f"{CONFIG}: final config is not exact managed gpt-6.2-sol config")
    if BASHRC.read_text(encoding="utf-8").count(PATH_BLOCK) != 1:
        final_problems.append(f"{BASHRC}: final exact Codex PATH block count is not 1")
    final_cache = model_cache_state(final_problems)
    if final_cache == "stale-other-version":
        final_problems.append(f"{MODEL_CACHE}: final model cache is still from another Codex client")
    if sorted(release_dir_names()) != [PINNED_RELEASE_DIR]:
        final_problems.append(f"{RELEASES_DIR}: final release set is {release_dir_names()!r}, expected {[PINNED_RELEASE_DIR]!r}")
    if not path_exists(STANDALONE_CURRENT) or not STANDALONE_CURRENT.is_symlink():
        final_problems.append(f"{STANDALONE_CURRENT}: final current link missing or not a symlink")
    elif pathlib.Path(os.readlink(STANDALONE_CURRENT)).name != PINNED_RELEASE_DIR:
        final_problems.append(f"{STANDALONE_CURRENT}: final current link does not point at {PINNED_RELEASE_DIR}")
    final_problems.extend(daemon_final_problems())
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
    print(f"[info] preflight app-server daemon: {state['daemon']}")
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

section "(c) enforce exact Codex config, PATH, cache, release tree, and app-server daemon"

codex_state_guard commit

section "success - Codex CLI installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so PATH updates take effect."
info "Run 'codex' and verify active state with /status."
info "Pinned Codex release: $CODEX_CLI_VERSION (standalone CLI, and Codex's app-server daemon when it exists)."
info "Managed default: model=gpt-6.2-sol, approval_policy=never, sandbox_mode=danger-full-access."
