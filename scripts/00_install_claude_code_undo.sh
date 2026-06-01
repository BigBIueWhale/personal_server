#!/usr/bin/env bash
# scripts/00_install_claude_code_undo.sh — defensively undo the per-user
# configuration written by 00_install_claude_code.sh.
#
# WHAT IT UNDOES (mirror image of the install script, in reverse order)
# ---------------------------------------------------------------------
#   (e) ~/.claude/CLAUDE.md: deletes the file ONLY IF it exists with the
#       exact byte content the install script writes (335 bytes, ending in
#       'patterns.\n').
#   (d) ~/.claude/settings.json: removes the five managed keys (three top-
#       level: model, effortLevel, showThinkingSummaries; two under env:
#       CLAUDE_CODE_EFFORT_LEVEL, CLAUDE_CODE_MAX_OUTPUT_TOKENS). Refuses
#       if ANY managed key is missing, or has a value other than the
#       install script's WANT. Unmanaged keys you have added (e.g. theme,
#       skipDangerousModePermissionPrompt) are preserved untouched. If the
#       env block becomes empty after removal, the env key itself is also
#       removed.
#   (c) ~/.bashrc marker-bracketed env block: removes the exact byte
#       sequence (leading newline + 10-line block + trailing newline) the
#       install script appended. Refuses unless that byte sequence appears
#       EXACTLY ONCE in the file.
#   (b) ~/.bashrc PATH addition: removes the exact 3-newline / 2-line
#       sequence (leading newline + comment + export) the install script
#       appends, but ONLY if it is actually present. If absent (because at
#       install time you already had some other ~/.local/bin PATH line and
#       step (b) was a no-op), this step is also a no-op — your pre-
#       existing line is not ours to remove. Refuses if the signature
#       appears more than once.
#   (a) install: NOT undone. The claude binary at ~/.local/bin/claude is
#       LEFT IN PLACE. This script ONLY reverses the configuration; it
#       never touches the binary, ~/.claude/projects/, ~/.claude/skills/,
#       ~/.claude/memory/, ~/.claude/todos/, transcripts, hooks, MCP
#       state, or any other accumulated Claude Code state.
#
# DESIGN — TWO-PHASE, ALL-OR-NOTHING
# ----------------------------------
# Phase 1: verify every precondition for every step against the install
#          script's canonical byte sequences. ALL problems are collected
#          before any decision is made; if there is even one, the script
#          prints every problem at once and exits non-zero having touched
#          NOTHING on disk.
# Phase 2: only if Phase 1 reports zero problems, all removals are
#          executed. Every write goes through tempfile + os.replace
#          (atomic rename) so a SIGINT mid-write cannot corrupt your
#          dotfiles. JSON output is re-parsed before being swapped in.
#
# The script never modifies a file partially. It either fully reverts
# every step, or touches nothing at all.
#
# MODEL VERSION COUPLING
# ----------------------
# The install script's `model` value (and its derived "Opus X.Y" comment
# wording) change between model releases. The other four managed keys
# (effortLevel=xhigh, showThinkingSummaries=true, env.CLAUDE_CODE_EFFORT_
# LEVEL=max, env.CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000) and the rest of
# the marker-block prose are constant across versions.
#
# This script accepts the model string as an optional positional argument
# so you can undo a state installed by an older version of the install
# script. The default matches the install script at the current commit.
#
# To undo the install script's CURRENT state:        (default)
#     bash scripts/00_install_claude_code_undo.sh
# To undo the state from Opus 4.7 (pre-4.8 upgrade):
#     bash scripts/00_install_claude_code_undo.sh 'claude-opus-4-7[1m]'
#
# Whatever model you pass, the on-disk state must match it exactly or the
# script refuses.
#
# Usage:
#   bash scripts/00_install_claude_code_undo.sh [MODEL_STRING]
#
# After it succeeds, open a NEW shell (or `source ~/.bashrc`) so the
# removed env vars are no longer set in subsequent processes, then re-run
# the install script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_ubuntu_noble
require_command python3

TARGET_USER="$(id -un)"
TARGET_HOME="$HOME"
[ "$TARGET_HOME" = "/home/$TARGET_USER" ] \
    || die "expected HOME=/home/$TARGET_USER, got '$TARGET_HOME' — refusing to write into a non-standard home"

BASHRC="$TARGET_HOME/.bashrc"
CLAUDE_DIR="$TARGET_HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"

[ -f "$BASHRC" ] || die "$BASHRC does not exist — nothing to undo for steps (b),(c)"

# ---------------------------------------------------------------------------
# constants — must mirror scripts/00_install_claude_code.sh byte-for-byte
# ---------------------------------------------------------------------------

# Default matches the install script's current WANT["model"]. Override by
# passing a different model string as $1 (e.g. 'claude-opus-4-7[1m]').
DEFAULT_MODEL='claude-opus-4-8[1m]'
MODEL="${1:-$DEFAULT_MODEL}"

# Derive the "Opus X.Y" human-readable version that appears inside the
# marker block's first comment line, from the model string. Format
# expected: 'claude-opus-N-M[…]' → 'N.M'. If extraction fails, abort
# rather than guess.
HR_VERSION="$(printf '%s' "$MODEL" | sed -nE 's/^claude-opus-([0-9]+)-([0-9]+)(\[.*\])?$/\1.\2/p')"
[ -n "$HR_VERSION" ] \
    || die "could not derive human-readable Opus version from MODEL='$MODEL' (expected form: claude-opus-N-M[1m])"

MARKER_BEGIN='# >>> claude code config (managed by 00_install_claude_code.sh) >>>'
MARKER_END='# <<< claude code config (managed by 00_install_claude_code.sh) <<<'

# Same heredoc construction as the install script. `read -r -d ''` reads
# until null delimiter; since the heredoc contains no null, it reads
# everything and returns failure (handled by `|| true`). Crucially,
# `read -r -d ''` STRIPS the heredoc's final trailing newline, so
# EXPECTED_BLOCK ends with '<<<', not with '\n'. Verified empirically.
read -r -d '' EXPECTED_BLOCK <<EOF || true
$MARKER_BEGIN
# Lock in maximum thinking effort for Opus $HR_VERSION (1M context).
# DO NOT EDIT lines inside this block by hand — 00_install_claude_code.sh
# will refuse to run if anything inside the markers has been changed.
# To customize, delete the entire block (markers and all), edit the script
# to match what you want, then re-run.
export CLAUDE_CODE_EFFORT_LEVEL=max
export ANTHROPIC_MODEL='$MODEL'
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
$MARKER_END
EOF

# Same string the install script's step (e) writes. Single-quoted heredoc-
# style multi-line literal; the trailing newline before the closing ' is
# part of the value. Verified: produces a 335-byte string when MODEL has
# no impact on this string (it doesn't — CLAUDE.md content is model-
# agnostic). Must match scripts/00_install_claude_code.sh exactly.
CLAUDEMD_CONTENT='This account'\''s work usually involves subtle infrastructure and
system-config tasks where wrong answers are expensive. Multi-step
reasoning is expected for any non-trivial change. Think carefully
before committing to a plan or making file edits. Verify assumptions
against actual file contents rather than memory of "typical" patterns.
'

# ---------------------------------------------------------------------------
# Hand off to Python for byte-exact verification + atomic writes
# ---------------------------------------------------------------------------

section "verify on-disk state matches the install script's output for MODEL='$MODEL'"

# Export everything Python needs to reconstruct the install script's exact
# byte sequences. Env-var passthrough handles embedded newlines fine.
export U_BASHRC="$BASHRC"
export U_SETTINGS="$SETTINGS"
export U_CLAUDEMD="$CLAUDEMD"
export U_MODEL="$MODEL"
export U_EXPECTED_BLOCK="$EXPECTED_BLOCK"
export U_CLAUDEMD_CONTENT="$CLAUDEMD_CONTENT"

python3 - <<'PYEOF'
import json
import os
import sys
import tempfile

BASHRC           = os.environ['U_BASHRC']
SETTINGS         = os.environ['U_SETTINGS']
CLAUDEMD         = os.environ['U_CLAUDEMD']
MODEL            = os.environ['U_MODEL']
EXPECTED_BLOCK   = os.environ['U_EXPECTED_BLOCK']
CLAUDEMD_CONTENT = os.environ['U_CLAUDEMD_CONTENT']

# Exact byte sequences the install script appends to ~/.bashrc.
#   step (c) — `{ printf '\n'; printf '%s\n' "$EXPECTED_BLOCK"; } >> "$BASHRC"`
#   step (b) — `{ printf '\n'; printf '# Added by ...\n'; printf 'export PATH...\n'; } >> "$BASHRC"`
STEP_C_APPEND = '\n' + EXPECTED_BLOCK + '\n'
STEP_B_APPEND = (
    '\n'
    '# Added by 00_install_claude_code.sh — claude lives in ~/.local/bin\n'
    'export PATH="$HOME/.local/bin:$PATH"\n'
)

# Same WANT/WANT_ENV constants as the install script. MODEL is the only
# one that varies per install-script version; the other four are stable.
WANT = {
    "model":                 MODEL,
    "effortLevel":           "xhigh",
    "showThinkingSummaries": True,
}
WANT_ENV = {
    "CLAUDE_CODE_EFFORT_LEVEL":      "max",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
}

# ---------------------------------------------------------------------------
# PHASE 1 — verify every precondition. Collect ALL problems before exiting.
# ---------------------------------------------------------------------------

problems = []

# Read ~/.bashrc once for both (b) and (c) checks.
with open(BASHRC, encoding='utf-8') as f:
    bashrc_text = f.read()

# (c) marker block append: must appear EXACTLY ONCE, byte-for-byte.
n_c = bashrc_text.count(STEP_C_APPEND)
if n_c != 1:
    problems.append(
        f"(c) ~/.bashrc: install script's marker-block append "
        f"(leading-LF + 10-line block + trailing-LF, {len(STEP_C_APPEND)} bytes, "
        f"derived for MODEL={MODEL!r}) must appear EXACTLY ONCE; found {n_c}. "
        f"Possible causes: the block was hand-edited; the block was installed "
        f"by a different model version (try passing that model as $1); the "
        f"file was mangled."
    )

# (b) PATH addition: may appear 0 or 1 times. 0 = install skipped because
# you had a pre-existing .local/bin PATH line; 1 = install wrote it and we
# will remove it. Anything else = refuse.
n_b = bashrc_text.count(STEP_B_APPEND)
if n_b > 1:
    problems.append(
        f"(b) ~/.bashrc: install script's PATH-addition signature "
        f"(leading-LF + comment + export, {len(STEP_B_APPEND)} bytes) found "
        f"{n_b} times. Expected 0 or 1."
    )

# (d) settings.json: must exist, parse as a JSON object, contain every
# managed key (top-level and env.*) with EXACTLY the install script's WANT
# value. ALSO refuses if env is missing entirely (install always sets it).
settings_data = None
if not os.path.isfile(SETTINGS):
    problems.append(
        f"(d) {SETTINGS}: file does not exist. The install script always "
        f"creates it."
    )
else:
    try:
        with open(SETTINGS, encoding='utf-8') as f:
            settings_data = json.load(f)
    except json.JSONDecodeError as e:
        problems.append(f"(d) {SETTINGS}: not valid JSON: {e}")
        settings_data = None

    if isinstance(settings_data, dict):
        for k, want_v in WANT.items():
            if k not in settings_data:
                problems.append(f"(d) {SETTINGS}: managed key {k!r} is missing")
            elif settings_data[k] != want_v:
                problems.append(
                    f"(d) {SETTINGS}: managed key {k!r} has value "
                    f"{settings_data[k]!r}, expected {want_v!r}"
                )
        env = settings_data.get("env")
        if env is None:
            problems.append(
                f"(d) {SETTINGS}: env block is missing entirely "
                f"(install script always creates env with two managed keys)"
            )
        elif not isinstance(env, dict):
            problems.append(
                f"(d) {SETTINGS}: env exists but is not a JSON object "
                f"(got {type(env).__name__})"
            )
        else:
            for k, want_v in WANT_ENV.items():
                if k not in env:
                    problems.append(f"(d) {SETTINGS}: env.{k} is missing")
                elif env[k] != want_v:
                    problems.append(
                        f"(d) {SETTINGS}: env.{k} has value "
                        f"{env[k]!r}, expected {want_v!r}"
                    )
    elif settings_data is not None:
        problems.append(f"(d) {SETTINGS}: top-level is not a JSON object")

# (e) CLAUDE.md: must exist as a regular file with the install script's
# exact byte content (including the trailing newline).
claudemd_text = None
if not os.path.isfile(CLAUDEMD):
    problems.append(
        f"(e) {CLAUDEMD}: file does not exist. The install script always "
        f"creates it."
    )
else:
    with open(CLAUDEMD, encoding='utf-8') as f:
        claudemd_text = f.read()
    if claudemd_text != CLAUDEMD_CONTENT:
        problems.append(
            f"(e) {CLAUDEMD}: byte content differs from what install script "
            f"writes. Have {len(claudemd_text)} bytes, expected "
            f"{len(CLAUDEMD_CONTENT)} bytes."
        )

if problems:
    print("[fatal] Phase 1 verification failed — refusing to revert anything.",
          file=sys.stderr)
    print("        No file has been touched.", file=sys.stderr)
    print("", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(2)

print("[info] Phase 1: all preconditions verified.")
print(f"[info]   (c) ~/.bashrc: marker block present exactly once ({len(STEP_C_APPEND)} bytes)")
print(f"[info]   (b) ~/.bashrc: PATH addition present: {'yes' if n_b == 1 else 'no (install skipped step b)'}")
print(f"[info]   (d) {SETTINGS}: all 5 managed keys match install WANT")
print(f"[info]   (e) {CLAUDEMD}: byte-for-byte match ({len(claudemd_text)} bytes)")

# ---------------------------------------------------------------------------
# PHASE 2 — execute removals. Each disk-mutating write is tempfile + atomic
# rename so a SIGINT mid-write cannot corrupt the file. Order: e -> d -> c
# -> b (reverse of install). Each step is independent; order is for
# narrative parity with the install script, not correctness.
# ---------------------------------------------------------------------------

print()
print("[info] Phase 2: executing removals.")

def atomic_write(path, content):
    """Write content to path via tempfile + os.replace (atomic on POSIX)."""
    dirpath = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + '.new.',
                               dir=dirpath)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

# (e) CLAUDE.md — delete the file (we verified byte-exact match in Phase 1).
os.unlink(CLAUDEMD)
print(f"[info]   (e) deleted {CLAUDEMD}")

# (d) settings.json — strip the five managed keys. Preserves insertion
# order of unmanaged keys (Python 3.7+ dict preserves insertion order, and
# pop() does not reorder remaining items). Drops the env subtree only if
# it becomes empty after removing both WANT_ENV keys.
for k in WANT:
    settings_data.pop(k, None)
env_block = settings_data.get("env", {})
for k in WANT_ENV:
    env_block.pop(k, None)
if not env_block:
    settings_data.pop("env", None)

# Same dump format the install script uses: indent=2, sort_keys=False,
# trailing newline. Re-parse before swapping in (sanity check).
new_settings_text = json.dumps(settings_data, indent=2, sort_keys=False) + "\n"
json.loads(new_settings_text)
atomic_write(SETTINGS, new_settings_text)
remaining_keys = list(settings_data.keys())
print(f"[info]   (d) stripped 5 managed keys from {SETTINGS};"
      f" remaining unmanaged keys: {remaining_keys or '(none)'}")

# (c)+(b) ~/.bashrc — remove the marker block append, and (if present)
# the PATH addition, in a single rewrite. Phase 1 guaranteed exactly one
# occurrence of (c) and 0-or-1 of (b), so .replace(_, _, 1) is safe.
new_bashrc = bashrc_text.replace(STEP_C_APPEND, '', 1)
assert new_bashrc != bashrc_text, "internal error: (c) replace was a no-op"
if n_b == 1:
    new_bashrc_2 = new_bashrc.replace(STEP_B_APPEND, '', 1)
    assert new_bashrc_2 != new_bashrc, "internal error: (b) replace was a no-op"
    new_bashrc = new_bashrc_2
atomic_write(BASHRC, new_bashrc)
removed_bytes = len(bashrc_text) - len(new_bashrc)
print(f"[info]   (c)+(b) rewrote {BASHRC} (-{removed_bytes} bytes)")

# ---------------------------------------------------------------------------
# Final cross-check: re-read everything and confirm we are in the post-
# undo state. This is belt-and-braces; an exception here means the script
# did less than it claimed.
# ---------------------------------------------------------------------------

with open(BASHRC, encoding='utf-8') as f:
    if STEP_C_APPEND in f.read():
        sys.exit("[fatal] post-state: STEP_C_APPEND still present in ~/.bashrc")
with open(BASHRC, encoding='utf-8') as f:
    if STEP_B_APPEND in f.read():
        sys.exit("[fatal] post-state: STEP_B_APPEND still present in ~/.bashrc")
with open(SETTINGS, encoding='utf-8') as f:
    after = json.load(f)
for k in WANT:
    if k in after:
        sys.exit(f"[fatal] post-state: managed key {k!r} still present in {SETTINGS}")
if "env" in after:
    for k in WANT_ENV:
        if k in after["env"]:
            sys.exit(f"[fatal] post-state: env.{k} still present in {SETTINGS}")
if os.path.exists(CLAUDEMD):
    sys.exit(f"[fatal] post-state: {CLAUDEMD} still exists")

print()
print("[info] Post-state cross-check passed.")
PYEOF

section "success — Claude Code configuration reverted"
info "Open a NEW shell (or 'source ~/.bashrc') so the removed env vars are no"
info "longer inherited by subsequently launched processes. Then re-run"
info "scripts/00_install_claude_code.sh to re-apply with the current install"
info "script's values (currently ANTHROPIC_MODEL=claude-opus-4-8[1m])."
