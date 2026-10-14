#!/usr/bin/env bash
# scripts/00_install_antigravity_cli_undo.sh — defensively undo the per-user
# Antigravity CLI configuration written by 00_install_antigravity_cli.sh.
#
# WHAT IT UNDOES (mirror image of the install script, in reverse order)
# ---------------------------------------------------------------------
#   (d) ~/.gemini/config/AGENTS.md: deletes the file ONLY IF it exists with the
#       exact byte content the install script writes (335 bytes, ending in
#       'patterns.\n'). Never touches ~/.gemini/config/rules/ or any other file.
#   (c) ~/.gemini/antigravity-cli/settings.json: removes the seven persistent
#       managed keys (allowNonWorkspaceAccess, artifactReviewPolicy, model,
#       showFeedbackSurvey, showTips, toolPermission, verbosity) plus the
#       server-synced `enableTelemetry: false` key if still present before first
#       `agy` launch. Refuses if ANY of the seven persistent managed keys is
#       missing or has a value other than the install script's WANT, or if any
#       sparse-false key (enableTelemetry, enableTerminalSandbox, useG1Credits)
#       is set to a non-false value. Unmanaged keys (such as trustedWorkspaces)
#       are preserved untouched.
#   (b) ~/.bashrc PATH addition: removes the exact 4-newline / 2-line sequence
#       appended by `agy install` (`\n\n# Added by Antigravity CLI installer\n
#       export PATH="/home/<user>/.local/bin:$PATH"\n`), if present. Refuses if
#       the marker appears with modified content or more than once.
#   (a) install: NOT undone. The agy binary at ~/.local/bin/agy is LEFT IN
#       PLACE. This script ONLY reverses the configuration; it never touches the
#       binary, ~/.gemini/antigravity-cli/brain/ conversations, logs, keyring
#       credentials, ~/.gemini/config/rules/, or any other accumulated state.
#
# DESIGN — TWO-PHASE, ALL-OR-NOTHING
# ----------------------------------
# Phase 1: verify every precondition for every step against the install
#          script's canonical values. ALL problems are collected before any
#          decision is made; if there is even one, the script prints every
#          problem at once and exits non-zero having touched NOTHING on disk.
# Phase 2: only if Phase 1 reports zero problems, all removals are executed.
#          Every file rewrite goes through tempfile + os.replace (atomic rename)
#          and JSON output is re-parsed before being swapped in.
#
# Usage:
#   bash scripts/00_install_antigravity_cli_undo.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ "$#" -ne 0 ]; then
    die "Usage: bash scripts/00_install_antigravity_cli_undo.sh (this script accepts no arguments or flags)"
fi

require_non_root
require_ubuntu_noble
require_command python3

TARGET_USER="$(id -un)"
TARGET_HOME="$HOME"
[ "$TARGET_HOME" = "/home/$TARGET_USER" ] \
    || die "expected HOME=/home/$TARGET_USER, got '$TARGET_HOME' — refusing to write into a non-standard home"

BASHRC="$TARGET_HOME/.bashrc"
GEMINI_DIR="$TARGET_HOME/.gemini"
AGY_DIR="$GEMINI_DIR/antigravity-cli"
SETTINGS="$AGY_DIR/settings.json"
CONFIG_DIR="$GEMINI_DIR/config"
AGENTSMD="$CONFIG_DIR/AGENTS.md"

[ -f "$BASHRC" ] || die "$BASHRC does not exist — nothing to undo for step (b)"

AGENTSMD_CONTENT='This account'\''s work usually involves subtle infrastructure and
system-config tasks where wrong answers are expensive. Multi-step
reasoning is expected for any non-trivial change. Think carefully
before committing to a plan or making file edits. Verify assumptions
against actual file contents rather than memory of "typical" patterns.
'

section "verify Antigravity CLI managed state before undo"

export U_BASHRC="$BASHRC"
export U_TARGET_HOME="$TARGET_HOME"
export U_SETTINGS="$SETTINGS"
export U_AGENTSMD="$AGENTSMD"
export U_AGENTSMD_CONTENT="$AGENTSMD_CONTENT"

python3 - <<'PYEOF'
import json
import os
import sys
import tempfile

BASHRC           = os.environ["U_BASHRC"]
TARGET_HOME      = os.environ["U_TARGET_HOME"]
SETTINGS         = os.environ["U_SETTINGS"]
AGENTSMD         = os.environ["U_AGENTSMD"]
AGENTSMD_CONTENT = os.environ["U_AGENTSMD_CONTENT"]

STEP_B_MARKER = "# Added by Antigravity CLI installer"
STEP_B_APPEND = (
    "\n\n"
    "# Added by Antigravity CLI installer\n"
    f'export PATH="{TARGET_HOME}/.local/bin:$PATH"\n'
)

WANT = {
    "allowNonWorkspaceAccess": True,
    "artifactReviewPolicy": "always-proceed",
    "model": "Gemini 4 Argon (High)",
    "showFeedbackSurvey": False,
    "showTips": False,
    "toolPermission": "always-proceed",
    "verbosity": "high",
}

SPARSE_FALSE_KEYS = (
    "enableTelemetry",
    "enableTerminalSandbox",
    "useG1Credits",
)


def same(a, b):
    return type(a) is type(b) and a == b


# ---------------------------------------------------------------------------
# PHASE 1 — verify every precondition. Collect ALL problems before exiting.
# ---------------------------------------------------------------------------

problems = []

with open(BASHRC, encoding="utf-8") as f:
    bashrc_text = f.read()

n_marker = bashrc_text.count(STEP_B_MARKER)
n_b = bashrc_text.count(STEP_B_APPEND)
if n_b > 1 or n_marker != n_b:
    problems.append(
        f"(b) {BASHRC}: unexpected Antigravity CLI PATH block state "
        f"(marker count={n_marker}, exact block count={n_b}; expected 0 or 1 exact match)."
    )

settings_data = None
if not os.path.lexists(SETTINGS):
    problems.append(
        f"(c) {SETTINGS}: file does not exist. The install script always creates it."
    )
elif os.path.islink(SETTINGS) or not os.path.isfile(SETTINGS):
    problems.append(f"(c) {SETTINGS}: exists but is not a regular file.")
else:
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            settings_data = json.load(f)
    except json.JSONDecodeError as e:
        problems.append(f"(c) {SETTINGS}: not valid JSON: {e}")
        settings_data = None

    if isinstance(settings_data, dict):
        for k, want_v in WANT.items():
            if k not in settings_data:
                problems.append(f"(c) {SETTINGS}: managed key {k!r} is missing")
            elif not same(settings_data[k], want_v):
                problems.append(
                    f"(c) {SETTINGS}: managed key {k!r} has value "
                    f"{settings_data[k]!r}, expected {want_v!r}"
                )
        for k in SPARSE_FALSE_KEYS:
            if k in settings_data and not same(settings_data[k], False):
                problems.append(
                    f"(c) {SETTINGS}: key {k!r} has value "
                    f"{settings_data[k]!r}, expected False or absent"
                )
    elif settings_data is not None:
        problems.append(f"(c) {SETTINGS}: top-level is not a JSON object")

agentsmd_text = None
if not os.path.lexists(AGENTSMD):
    problems.append(
        f"(d) {AGENTSMD}: file does not exist. The install script always creates it."
    )
elif os.path.islink(AGENTSMD) or not os.path.isfile(AGENTSMD):
    problems.append(f"(d) {AGENTSMD}: exists but is not a regular file.")
else:
    with open(AGENTSMD, encoding="utf-8") as f:
        agentsmd_text = f.read()
    if agentsmd_text != AGENTSMD_CONTENT:
        problems.append(
            f"(d) {AGENTSMD}: byte content differs from what install script "
            f"writes. Have {len(agentsmd_text)} bytes, expected "
            f"{len(AGENTSMD_CONTENT)} bytes."
        )

if problems:
    print(
        "[fatal] Phase 1 verification failed — refusing to revert anything.",
        file=sys.stderr,
    )
    print("        No file has been touched.", file=sys.stderr)
    print("", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(2)

print("[info] Phase 1: all preconditions verified.")
print(
    f"[info]   (b) {BASHRC}: PATH addition present: "
    f"{'yes' if n_b == 1 else 'no'}"
)
print(f"[info]   (c) {SETTINGS}: all 7 persistent managed keys match install WANT")
print(f"[info]   (d) {AGENTSMD}: byte-for-byte match ({len(agentsmd_text)} bytes)")

# ---------------------------------------------------------------------------
# PHASE 2 — execute removals atomically. Order: d -> c -> b.
# ---------------------------------------------------------------------------

print()
print("[info] Phase 2: executing removals.")


def atomic_write(path, content):
    real = os.path.realpath(path)
    dirpath = os.path.dirname(real) or "."
    mode = os.stat(real).st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(real) + ".new.", dir=dirpath)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


# (d) AGENTS.md — delete the file.
os.unlink(AGENTSMD)
print(f"[info]   (d) deleted {AGENTSMD}")

# (c) settings.json — strip the seven persistent managed keys and any
# sparse-false keys, preserving unmanaged keys (such as trustedWorkspaces).
for k in WANT:
    settings_data.pop(k, None)
for k in SPARSE_FALSE_KEYS:
    settings_data.pop(k, None)

new_settings_text = json.dumps(settings_data, indent=2, sort_keys=True) + "\n"
json.loads(new_settings_text)
atomic_write(SETTINGS, new_settings_text)
remaining_keys = list(settings_data.keys())
print(
    f"[info]   (c) stripped managed keys from {SETTINGS}; "
    f"remaining unmanaged keys: {remaining_keys or '(none)'}"
)

# (b) ~/.bashrc — remove the PATH addition if present.
if n_b == 1:
    new_bashrc = bashrc_text.replace(STEP_B_APPEND, "", 1)
    assert new_bashrc != bashrc_text, "internal error: (b) replace was a no-op"
    atomic_write(BASHRC, new_bashrc)
    removed_bytes = len(bashrc_text) - len(new_bashrc)
    print(f"[info]   (b) rewrote {BASHRC} (-{removed_bytes} bytes)")
else:
    print(f"[info]   (b) no Antigravity CLI PATH block in {BASHRC}; leaving alone")

# ---------------------------------------------------------------------------
# Final cross-check
# ---------------------------------------------------------------------------

with open(BASHRC, encoding="utf-8") as f:
    after_bashrc = f.read()
    if STEP_B_APPEND in after_bashrc or STEP_B_MARKER in after_bashrc:
        sys.exit("[fatal] post-state: Antigravity PATH block still present in ~/.bashrc")
with open(SETTINGS, encoding="utf-8") as f:
    after = json.load(f)
for k in WANT:
    if k in after:
        sys.exit(f"[fatal] post-state: managed key {k!r} still present in {SETTINGS}")
for k in SPARSE_FALSE_KEYS:
    if k in after:
        sys.exit(f"[fatal] post-state: key {k!r} still present in {SETTINGS}")
if os.path.lexists(AGENTSMD):
    sys.exit(f"[fatal] post-state: {AGENTSMD} still exists")

print()
print("[info] Post-state cross-check passed.")
PYEOF

section "success — Antigravity CLI configuration reverted"
info "Antigravity CLI binary (~/.local/bin/agy), authentication, conversations,"
info "rules (~/.gemini/config/rules/), and unmanaged settings.json keys (such as"
info "trustedWorkspaces) were intentionally preserved."
