#!/usr/bin/env bash
# scripts/00_install_claude_code.sh — install Claude Code CLI and configure
# max-effort defaults for Opus 4.7 (1M).
#
# WHY THIS IS THE FIRST SCRIPT
# ----------------------------
# This is `00_` (run before `01_…`) on purpose. Once Claude Code is
# installed and configured, Claude itself can guide the user through (or
# simply execute) the remaining numbered scripts. Setting it up first turns
# every later step into "ask Claude" instead of "follow the README".
#
# WHAT IT DOES (in order; each step is idempotent — see IDEMPOTENCY below)
# ------------------------------------------------------------------------
#   (a) Install: pipe Anthropic's official binary installer
#       (https://claude.ai/install.sh) into bash. Lands the binary at
#       /home/<user>/.local/bin/claude. Skipped if the binary is already
#       there.
#   (b) PATH: ensure /home/<user>/.local/bin is on PATH via /home/<user>/
#       .bashrc (so subsequent terminal sessions can run `claude`). Skipped
#       if any `export PATH=…` line already references `.local/bin`.
#   (c) bashrc env block: append a marker-delimited block to
#       /home/<user>/.bashrc with three env exports that lock in maximum
#       thinking effort on Opus 4.7 (1M). Marker text is fixed and the
#       block is verified byte-for-byte on re-run.
#   (d) settings.json: merge five managed keys into /home/<user>/
#       .claude/settings.json. Pre-existing user-set keys are preserved.
#       If any of our managed keys already exists with a value different
#       from what we'd write, the script REFUSES.
#   (e) CLAUDE.md: create /home/<user>/.claude/CLAUDE.md with the adaptive-
#       thinking nudge text. If the file already exists with different
#       content, the script REFUSES.
#
# IDEMPOTENCY (by design — re-running this script is safe)
# --------------------------------------------------------
# Every write is a three-way decision: already-correct → no-op; absent →
# write; conflicting → REFUSE LOUDLY (never silently overwrite). Concretely:
#
#   - The .bashrc env block is bracketed by `# >>> claude code config …`
#     and `# <<< claude code config …` markers. On re-run we extract the
#     existing block and compare to what we'd write. Match → skipped.
#     Mismatch (anyone — you, Claude, an editor — has changed a line
#     inside the markers) → fatal. Fix the block by hand or delete it
#     entirely, then re-run.
#   - settings.json is parsed as JSON. For each managed key we check:
#     present-and-equal → leave alone; present-and-different → fatal;
#     absent → set. Unmanaged keys are preserved untouched. The merged
#     file is written via a tempfile + atomic rename, so a SIGINT mid-
#     write cannot corrupt settings.json.
#   - CLAUDE.md is created only if absent. If it exists with our exact
#     bytes, no-op. If it exists with anything else, fatal.
#
# This means the worst case for a re-run is "script complains and exits
# non-zero". It does NOT silently double-append, double-edit, or revert
# user changes.
#
# RUN AS THE DESKTOP USER (NOT sudo)
# ----------------------------------
# Claude Code installs into /home/<user>/.local/bin/claude and stores
# config under /home/<user>/.claude/. Running as root would land
# everything in /root/, useless to the desktop user. The script enforces
# this with require_non_root.
#
# Usage:
#   bash scripts/00_install_claude_code.sh
#
# After it finishes, open a new shell (or `source ~/.bashrc`) so the new
# env block takes effect, then run `claude` and walk through the
# authentication flow on first launch.

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

BASHRC="$TARGET_HOME/.bashrc"
[ -f "$BASHRC" ] || die "$BASHRC does not exist — this script edits .bashrc and cannot proceed"

CLAUDE_DIR="$TARGET_HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
LOCAL_BIN="$TARGET_HOME/.local/bin"
CLAUDE_BIN="$LOCAL_BIN/claude"

# ---------------------------------------------------------------------------
# (a) install Claude Code via Anthropic's official installer
# ---------------------------------------------------------------------------
#
# The installer downloads a signed native binary for the current platform and
# places it at $HOME/.local/bin/claude. There is no published SHA for
# install.sh itself — Anthropic's chain of trust is on the binary the
# installer fetches, not on install.sh. We therefore do not attempt to
# verify install.sh and just run it the way the docs document it.

INSTALLER_URL="https://claude.ai/install.sh"

section "(a) install Claude Code via $INSTALLER_URL"

if [ -e "$CLAUDE_BIN" ]; then
    [ -x "$CLAUDE_BIN" ] || die "$CLAUDE_BIN exists but is not executable — refusing to touch it"
    info "$CLAUDE_BIN already exists — skipping installer (re-run is idempotent)"
else
    info "downloading and running $INSTALLER_URL"
    curl -fsSL "$INSTALLER_URL" | bash
    [ -x "$CLAUDE_BIN" ] \
        || die "after running installer, $CLAUDE_BIN does not exist or is not executable — installer must have failed"
fi

# Run --version via full path; we have not yet confirmed PATH includes ~/.local/bin
# in this shell (that's step (b) below).
VER_LINE="$("$CLAUDE_BIN" --version 2>&1 | head -1 || true)"
[ -n "$VER_LINE" ] || die "'$CLAUDE_BIN --version' produced no output"
info "claude --version: $VER_LINE"

# ---------------------------------------------------------------------------
# (b) ensure ~/.local/bin is on PATH in ~/.bashrc
# ---------------------------------------------------------------------------
#
# Anthropic's installer may or may not append a PATH line itself (depends
# on shell detection and existing config). We check for ANY `export PATH=…`
# line that mentions `.local/bin` and only append if there is none.
# Tolerant of common variants ($HOME, ${HOME}, /home/<user>, with or
# without quotes).

section "(b) ~/.local/bin on PATH in $BASHRC"

if grep -Eq '^[[:space:]]*export[[:space:]]+PATH=.*\.local/bin' "$BASHRC"; then
    info "$BASHRC already has an 'export PATH=' line that references .local/bin — leaving alone"
else
    info "appending PATH export to $BASHRC (no existing reference to .local/bin found)"
    {
        printf '\n'
        printf '# Added by 00_install_claude_code.sh — claude lives in ~/.local/bin\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$BASHRC"
fi

# ---------------------------------------------------------------------------
# (c) marker-delimited env block in ~/.bashrc
# ---------------------------------------------------------------------------
#
# Why each export — recap (full justification is in the repo's commit
# history; quoting is verified against Anthropic's docs as of 2026-04):
#
#   CLAUDE_CODE_EFFORT_LEVEL=max
#       Only persistent path to 'max'. The env var is highest in the
#       precedence chain (env > skill/subagent frontmatter > /effort >
#       settings.json effortLevel > model default). settings.json's
#       `effortLevel` field cannot hold "max" — the schema enum drops it
#       (anthropics/claude-code GitHub issue #50557).
#
#   ANTHROPIC_MODEL='claude-opus-4-7[1m]'
#       Pin the exact model + 1M context. Immune to the `opus` alias
#       remapping to a future model.
#
#   CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
#       Raise the per-response output ceiling to Opus 4.7's max so that
#       adaptive thinking + the answer have room to breathe (they share
#       this budget).
#
# Marker convention: a fixed begin/end pair so the block can be located,
# verified, or removed deterministically across re-runs.

section "(c) Claude Code env block in $BASHRC"

MARKER_BEGIN='# >>> claude code config (managed by 00_install_claude_code.sh) >>>'
MARKER_END='# <<< claude code config (managed by 00_install_claude_code.sh) <<<'

# The expected block — every byte must match on re-run, or the script
# refuses to touch the file.
read -r -d '' EXPECTED_BLOCK <<EOF || true
$MARKER_BEGIN
# Lock in maximum thinking effort for Opus 4.7 (1M context).
# DO NOT EDIT lines inside this block by hand — 00_install_claude_code.sh
# will refuse to run if anything inside the markers has been changed.
# To customize, delete the entire block (markers and all), edit the script
# to match what you want, then re-run.
export CLAUDE_CODE_EFFORT_LEVEL=max
export ANTHROPIC_MODEL='claude-opus-4-7[1m]'
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
$MARKER_END
EOF

# Count the markers to detect a malformed (mismatched-marker) state early.
N_BEGIN="$(grep -cFx "$MARKER_BEGIN" "$BASHRC" || true)"
N_END="$(grep -cFx "$MARKER_END"   "$BASHRC" || true)"
[ "$N_BEGIN" = "$N_END" ] \
    || die "$BASHRC has $N_BEGIN '$MARKER_BEGIN' lines but $N_END '$MARKER_END' lines — markers are unbalanced; refusing to touch"
[ "$N_BEGIN" -le 1 ] \
    || die "$BASHRC has $N_BEGIN copies of the Claude Code env block — there must be at most one; refusing to touch"

if [ "$N_BEGIN" = "1" ]; then
    # Extract the existing block (first BEGIN line through first END line, inclusive).
    EXISTING_BLOCK="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { p=1 }
        p { print }
        $0 == e { exit }
    ' "$BASHRC")"
    if [ "$EXISTING_BLOCK" = "$EXPECTED_BLOCK" ]; then
        info "Claude Code env block already present and matches expected content — no change"
    else
        die "$(printf 'FATAL: existing Claude Code env block in %s does not match expected content.\nRefusing to overwrite. To proceed:\n  1. Open %s in an editor.\n  2. Delete the entire block (lines from "%s"\n     through "%s" inclusive).\n  3. Re-run this script.' "$BASHRC" "$BASHRC" "$MARKER_BEGIN" "$MARKER_END")"
    fi
else
    info "appending Claude Code env block to $BASHRC"
    {
        printf '\n'
        printf '%s\n' "$EXPECTED_BLOCK"
    } >> "$BASHRC"
fi

# ---------------------------------------------------------------------------
# (d) merge managed keys into ~/.claude/settings.json
# ---------------------------------------------------------------------------
#
# Managed keys (top-level):
#     model                  = "claude-opus-4-7[1m]"
#     effortLevel            = "xhigh"          (fallback: schema drops "max")
#     showThinkingSummaries  = true             (4.7 hides thinking by default)
#
# Managed keys (under env): duplicates of the bashrc exports, so any
# launch path that doesn't source .bashrc (GNOME/KDE desktop launchers,
# IDE-integrated terminals) still gets max effort.
#     env.CLAUDE_CODE_EFFORT_LEVEL    = "max"
#     env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = "128000"
#
# Behavior on re-run: each managed key is checked individually. If absent
# we set it; if present with the right value we leave it alone; if
# present with a different value the script aborts with a precise
# diagnostic. Unmanaged keys (yours: theme, skipDangerousModePermission-
# Prompt, anything else you've added) are preserved untouched.

section "(d) merge managed keys into $SETTINGS"

mkdir -p "$CLAUDE_DIR"
if [ ! -e "$SETTINGS" ]; then
    info "$SETTINGS does not exist — initializing with empty object"
    printf '{}\n' > "$SETTINGS"
fi
[ -f "$SETTINGS" ] || die "$SETTINGS exists but is not a regular file"

# Compute merged result via python3 (jq is not guaranteed at this stage of
# the install). Tempfile + atomic rename so a SIGINT mid-write can't
# corrupt the file.
TMP_SETTINGS="$(mktemp "${SETTINGS}.new.XXXXXX")"
trap 'rm -f -- "$TMP_SETTINGS"' EXIT

python3 - "$SETTINGS" "$TMP_SETTINGS" <<'PYEOF'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]

WANT = {
    "model": "claude-opus-4-7[1m]",
    "effortLevel": "xhigh",
    "showThinkingSummaries": True,
}
WANT_ENV = {
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
}

try:
    with open(src) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"[fatal] {src} is not valid JSON: {e}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(f"[fatal] {src} is not a JSON object (top-level must be {{...}})", file=sys.stderr)
    sys.exit(2)

mismatches = []
for k, v in WANT.items():
    if k in data and data[k] != v:
        mismatches.append(f"  {k}: have {data[k]!r}, want {v!r}")

env = data.get("env")
if env is None:
    env = {}
elif not isinstance(env, dict):
    print(f"[fatal] {src} has 'env' but it is not a JSON object (got {type(env).__name__})",
          file=sys.stderr)
    sys.exit(2)

for k, v in WANT_ENV.items():
    if k in env and env[k] != v:
        mismatches.append(f"  env.{k}: have {env[k]!r}, want {v!r}")

if mismatches:
    print(f"[fatal] existing values in {src} differ from what this script wants:",
          file=sys.stderr)
    for m in mismatches:
        print(m, file=sys.stderr)
    print("Refusing to overwrite. To proceed: open the file by hand,", file=sys.stderr)
    print("either change the values to the wanted ones or delete the", file=sys.stderr)
    print("conflicting keys, then re-run this script.", file=sys.stderr)
    sys.exit(2)

for k, v in WANT.items():
    data[k] = v
data["env"] = env
for k, v in WANT_ENV.items():
    env[k] = v

with open(dst, "w") as f:
    json.dump(data, f, indent=2, sort_keys=False)
    f.write("\n")
PYEOF

# Sanity: parse the temp file we just wrote, before swapping it in.
python3 -c "import json; json.load(open('$TMP_SETTINGS'))" \
    || die "merged settings.json failed to re-parse — refusing to install it; original $SETTINGS untouched"

mv -- "$TMP_SETTINGS" "$SETTINGS"
trap - EXIT

info "$SETTINGS now contains:"
cat -- "$SETTINGS"

# ---------------------------------------------------------------------------
# (e) ~/.claude/CLAUDE.md adaptive-thinking nudge
# ---------------------------------------------------------------------------
#
# Opus 4.7 always uses adaptive reasoning — there is no API switch to force
# fixed-large thinking. The only documented way to bias the per-turn
# adaptive trigger upward is system-prompt / CLAUDE.md guidance:
# https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking

section "(e) create $CLAUDEMD"

CLAUDEMD_CONTENT='This account'\''s work usually involves subtle infrastructure and
system-config tasks where wrong answers are expensive. Multi-step
reasoning is expected for any non-trivial change. Think carefully
before committing to a plan or making file edits. Verify assumptions
against actual file contents rather than memory of "typical" patterns.
'

if [ -e "$CLAUDEMD" ]; then
    [ -f "$CLAUDEMD" ] || die "$CLAUDEMD exists but is not a regular file — refusing to touch"
    EXISTING_MD="$(cat -- "$CLAUDEMD")"
    if [ "$EXISTING_MD" = "$CLAUDEMD_CONTENT" ]; then
        info "$CLAUDEMD already present and matches expected content — no change"
    else
        die "$(printf 'FATAL: %s already exists with different content.\nRefusing to overwrite. If the existing content is your own customization,\nleave it. If it is stale and you want this script to manage it again,\ndelete the file and re-run.' "$CLAUDEMD")"
    fi
else
    printf '%s' "$CLAUDEMD_CONTENT" > "$CLAUDEMD"
    info "created $CLAUDEMD"
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------

section "success — Claude Code installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so the new env block takes effect."
info "Then run 'claude' and walk through the authentication flow on first launch."
info "Inside a session, verify max effort with the '/effort' slash command."
