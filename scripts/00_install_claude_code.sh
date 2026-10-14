#!/usr/bin/env bash
# scripts/00_install_claude_code.sh — install Claude Code CLI and configure
# Extra-high effort, full autonomy (bypassPermissions), and privacy/anti-nag
# defaults for Opus 5.5 with 1M context (claude-opus-5-5[1m]).
#
# WHY THIS IS THE FIRST SCRIPT
# ----------------------------
# This is `00_` (run before `01_…`) on purpose. Once Claude Code is
# installed and configured, Claude itself can guide the user through (or
# simply execute) the remaining numbered scripts. Setting it up first turns
# every later step into "ask Claude" instead of "follow the README".
#
# WHAT IT DOES (in order; each step is idempotent — see CONFIGURATION SAFETY)
# ------------------------------------------------------------------------
#   (0) Check: every managed item in (c)-(e) is checked before anything is
#       changed, so a refusal leaves the machine as it was.
#   (a) Install: pipe Anthropic's official binary installer
#       (https://claude.ai/install.sh) into bash. Lands the binary at
#       /home/<user>/.local/bin/claude. Re-running updates it on the latest
#       channel when a newer release is available.
#   (b) PATH: ensure /home/<user>/.local/bin is on PATH via /home/<user>/
#       .bashrc (so subsequent terminal sessions can run `claude`). Skipped
#       if any `export PATH=…` line already references `.local/bin`.
#   (c) bashrc env block: append a marker-delimited block to
#       /home/<user>/.bashrc with eight env exports that set Opus 5.5 (1M
#       context) and Extra-high effort for the main session and all subagents,
#       the 128K output ceiling, and opt-outs for error reporting, feedback
#       surveys, and `/feedback` transcript uploads. Marker text is fixed and
#       the block is verified byte-for-byte on re-run.
#   (d) settings.json: merge sixteen managed keys (eight top-level, one under
#       permissions, seven under env) into /home/<user>/.claude/settings.json
#       for Opus 5.5 (1M context), Extra-high effort, full autonomy
#       (permissions.defaultMode = "bypassPermissions",
#       skipDangerousModePermissionPrompt = true, switchModelsOnFlag = false),
#       and privacy/UI preferences (feedbackDrafts = "off",
#       feedbackSurveyRate = 0, spinnerTipsEnabled = false, plus env opt-outs).
#       Pre-existing user-set keys are preserved. If any managed key differs,
#       the script REFUSES.
#   (e) CLAUDE.md: create /home/<user>/.claude/CLAUDE.md with the adaptive-
#       thinking nudge text. If the file already exists with different
#       content, the script REFUSES.
#
# CONFIGURATION SAFETY (by design — re-running this script is safe)
# ---------------------------------------------------------------
# The binary is updated from Anthropic's latest channel on every run.
# Configuration writes are decisions per managed item: already-correct →
# no-op; absent → write; exactly as the previous revision of this script
# left it → upgrade in place; anything else → REFUSE LOUDLY. Every item is
# checked before anything is changed, the binary included, so a refusal
# leaves the machine as it was. Concretely:
#
#   - The .bashrc env block is bracketed by `# >>> claude code config …`
#     and `# <<< claude code config …` markers. On re-run we extract the
#     existing block and compare to what we'd write. Match → skipped.
#     Byte-identical to the previous revision's block → replaced in place,
#     every other byte of .bashrc kept. Any other mismatch (anyone — you,
#     Claude, an editor — changed a line inside the markers) → fatal. Fix
#     the block by hand or delete it entirely.
#   - settings.json is parsed as JSON. Each managed key is decided on its
#     own: present-and-equal → leave alone; absent → set; holding the value
#     the previous revision of this script wrote → upgraded; any other value
#     → fatal. Values compare type-strictly (1 is not true). A key added
#     since the previous revision has no previous value, so it upgrades only
#     from absent. Unmanaged keys are preserved untouched. The merged file is written via a
#     tempfile + atomic rename, so a SIGINT mid-write cannot corrupt
#     settings.json.
#   - CLAUDE.md is created only if absent. If it exists with our exact
#     bytes, no-op. If it exists with anything else, fatal.
#
# It does NOT silently double-append, double-edit, or revert user
# configuration changes.
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
# Managed configuration
# ---------------------------------------------------------------------------
#
# Why each .bashrc export — recap (full justification is in the repo's commit
# history; values are verified against Anthropic's current docs):
#
#   CLAUDE_CODE_EFFORT_LEVEL=xhigh
#       The environment variable sets Extra-high effort for Opus 5.5 in
#       terminal and GUI launches, including subagents. Opus 5.5 otherwise
#       defaults to `medium`.
#
#   ANTHROPIC_MODEL='claude-opus-5-5[1m]'
#       Pin the exact model with its 1M-context suffix, the ID Claude Code's
#       /model writes for Opus 5.5 (1M context). The full ID does not drift
#       with the `opus` alias when a later Opus ships.
#
#   CLAUDE_CODE_SUBAGENT_MODEL='claude-opus-5-5[1m]'
#   CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
#       Pin every subagent, including built-in Explore and Plan, to the
#       same model even when an agent definition requests another model.
#
#   CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
#       Raise the per-response output ceiling to Opus 5.5's max (128k) so
#       that adaptive thinking + the answer have room to breathe (they
#       share this budget).
#
#   DISABLE_ERROR_REPORTING=1
#       Opt out of sending Claude Code internal error messages and stack
#       traces to Anthropic's third-party error tracking service (otherwise
#       enabled by default on Pro/Max plans since v2.1.198). Unlike
#       DISABLE_TELEMETRY or CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, this
#       does NOT disable GrowthBook feature-flag evaluation (preserving
#       Remote Control, synced skills/plugins, advisor, and idle compaction).
#
#   CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
#       Disable the "How is Claude doing this session?" survey and its
#       follow-up transcript-share prompt without disabling feature flags.
#
#   DISABLE_FEEDBACK_COMMAND=1
#       Disable `/feedback`, `/bug`, `/share`, and Claude-drafted feedback
#       uploads (which otherwise upload transcripts to GCS for 5 years).
#
# Marker convention: a fixed begin/end pair so the block can be located,
# verified, or removed deterministically across re-runs.
#
# PREVIOUS_BLOCK / OLDER_BLOCK, and PREVIOUS / PREVIOUS_ENV in settings_merge,
# are exactly what the preceding revisions of this script wrote. Those values,
# and only those, are upgraded in place -- the .bashrc block as a whole,
# settings.json key by key; any other difference from the current values is a
# hand edit and is refused.

MARKER_BEGIN='# >>> claude code config (managed by 00_install_claude_code.sh) >>>'
MARKER_END='# <<< claude code config (managed by 00_install_claude_code.sh) <<<'

read -r -d '' EXPECTED_BLOCK <<EOF || true
$MARKER_BEGIN
# Lock in Extra-high thinking effort for Opus 5.5 (1M context).
# DO NOT EDIT lines inside this block by hand — 00_install_claude_code.sh
# will refuse to run if anything inside the markers has been changed.
# To customize, delete the entire block (markers and all), edit the script
# to match what you want, then re-run.
export CLAUDE_CODE_EFFORT_LEVEL=xhigh
export ANTHROPIC_MODEL='claude-opus-5-5[1m]'
export CLAUDE_CODE_SUBAGENT_MODEL='claude-opus-5-5[1m]'
export CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
export DISABLE_ERROR_REPORTING=1
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
export DISABLE_FEEDBACK_COMMAND=1
$MARKER_END
EOF

read -r -d '' PREVIOUS_BLOCK <<EOF || true
$MARKER_BEGIN
# Lock in Extra-high thinking effort for Opus 5.5 (1M context).
# DO NOT EDIT lines inside this block by hand — 00_install_claude_code.sh
# will refuse to run if anything inside the markers has been changed.
# To customize, delete the entire block (markers and all), edit the script
# to match what you want, then re-run.
export CLAUDE_CODE_EFFORT_LEVEL=xhigh
export ANTHROPIC_MODEL='claude-opus-5-5[1m]'
export CLAUDE_CODE_SUBAGENT_MODEL='claude-opus-5-5[1m]'
export CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
$MARKER_END
EOF

read -r -d '' OLDER_BLOCK <<EOF || true
$MARKER_BEGIN
# Lock in Extra-high thinking effort for Opus 5.5 (1M context).
# DO NOT EDIT lines inside this block by hand — 00_install_claude_code.sh
# will refuse to run if anything inside the markers has been changed.
# To customize, delete the entire block (markers and all), edit the script
# to match what you want, then re-run.
export CLAUDE_CODE_EFFORT_LEVEL=xhigh
export ANTHROPIC_MODEL='claude-opus-5-5'
export CLAUDE_CODE_SUBAGENT_MODEL='claude-opus-5-5'
export CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
$MARKER_END
EOF

CLAUDEMD_CONTENT='This account'\''s work usually involves subtle infrastructure and
system-config tasks where wrong answers are expensive. Multi-step
reasoning is expected for any non-trivial change. Think carefully
before committing to a plan or making file edits. Verify assumptions
against actual file contents rather than memory of "typical" patterns.
'

# The state helpers below print one word or die. Capture them with a plain
# assignment (STATE="$(helper)") so a refusal stops the script: inside a test
# or `case` the failure would be swallowed.

# Prints the .bashrc env block state: absent, current or previous. Dies on
# unbalanced or repeated markers, or a block that is neither.
bashrc_block_state() {
    local n_begin n_end existing
    n_begin="$(grep -cFx "$MARKER_BEGIN" "$BASHRC" || true)"
    n_end="$(grep -cFx "$MARKER_END" "$BASHRC" || true)"
    [ "$n_begin" = "$n_end" ] \
        || die "$BASHRC has $n_begin '$MARKER_BEGIN' lines but $n_end '$MARKER_END' lines — markers are unbalanced; refusing to touch"
    [ "$n_begin" -le 1 ] \
        || die "$BASHRC has $n_begin copies of the Claude Code env block — there must be at most one; refusing to touch"
    if [ "$n_begin" = 0 ]; then
        echo absent
        return
    fi
    # First BEGIN line through first END line, inclusive.
    existing="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { p=1 }
        p { print }
        $0 == e { exit }
    ' "$BASHRC")"
    if [ "$existing" = "$EXPECTED_BLOCK" ]; then
        echo current
    elif [ "$existing" = "$PREVIOUS_BLOCK" ] || [ "$existing" = "$OLDER_BLOCK" ]; then
        echo previous
    else
        die "$(printf 'FATAL: existing Claude Code env block in %s does not match expected content.\nRefusing to overwrite. To proceed:\n  1. Open %s in an editor.\n  2. Delete the entire block (lines from "%s"\n     through "%s" inclusive).\n  3. Re-run this script.' "$BASHRC" "$BASHRC" "$MARKER_BEGIN" "$MARKER_END")"
    fi
}

# Replaces a previous revision's block with EXPECTED_BLOCK, keeping every
# other byte of .bashrc. The new file is written beside the real one (through a
# symlink, if .bashrc is one), keeps its mode, and is renamed over it.
replace_previous_block() {
    python3 - "$BASHRC" "$MARKER_BEGIN" "$MARKER_END" "$PREVIOUS_BLOCK" "$OLDER_BLOCK" "$EXPECTED_BLOCK" <<'PYEOF'
import os
import sys
import tempfile

path = os.path.realpath(sys.argv[1])
begin, end, previous, older, expected = (s.encode("utf-8") for s in sys.argv[2:7])

with open(path, "rb") as f:
    lines = f.read().splitlines(keepends=True)

begins = [i for i, line in enumerate(lines) if line.removesuffix(b"\n") == begin]
ends = [i for i, line in enumerate(lines) if line.removesuffix(b"\n") == end]
if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
    sys.exit(f"[fatal] {path}: cannot locate exactly one Claude Code env block")
b, e = begins[0], ends[0]
newline = b"\n" if lines[e].endswith(b"\n") else b""
existing = b"".join(lines[b:e + 1])
if existing not in (previous + newline, older + newline):
    sys.exit(f"[fatal] {path}: the Claude Code env block is not a previous revision's block; refusing to replace it")

text = b"".join(lines[:b]) + expected + newline + b"".join(lines[e + 1:])
mode = os.stat(path).st_mode & 0o7777
fd, tmp = tempfile.mkstemp(prefix=".bashrc.new.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "wb") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)
except BaseException:
    if os.path.lexists(tmp):
        os.unlink(tmp)
    raise
PYEOF
}

# Decides the settings.json merge and, in write mode, writes the merged result
# to DEST. Prints the state it found: current, previous (some managed keys
# hold the previous revision's values) or missing (some are absent). Exits 2, naming every conflict, on anything else.
#   settings_merge check SETTINGS
#   settings_merge write SETTINGS DEST
settings_merge() {
    python3 - "$@" <<'PYEOF'
import json
import os
import sys

mode, src = sys.argv[1], sys.argv[2]

WANT = {
    "model": "claude-opus-5-5[1m]",
    "effortLevel": "xhigh",
    "showThinkingSummaries": True,
    "skipDangerousModePermissionPrompt": True,
    "switchModelsOnFlag": False,
    "feedbackDrafts": "off",
    "feedbackSurveyRate": 0,
    "spinnerTipsEnabled": False,
}
WANT_PERMISSIONS = {
    "defaultMode": "bypassPermissions",
}
WANT_ENV = {
    "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5-5[1m]",
    "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
    "DISABLE_ERROR_REPORTING": "1",
    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
    "DISABLE_FEEDBACK_COMMAND": "1",
}
# Values from the earlier claude-opus-5-5 (non-[1m]) revision of this script.
PREVIOUS = {
    "model": "claude-opus-5-5",
    "effortLevel": "xhigh",
    "showThinkingSummaries": True,
}
PREVIOUS_ENV = {
    "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5-5",
    "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
}


def fail(*lines):
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(2)


def same(a, b):
    return type(a) is type(b) and a == b


def holds(obj, want):
    return all(k in obj and same(obj[k], v) for k, v in want.items())


data = {}
if os.path.lexists(src):
    if not os.path.isfile(src):
        fail(f"[fatal] {src} exists but is not a regular file")
    try:
        with open(src) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        fail(f"[fatal] {src} is not valid JSON: {e}")
if not isinstance(data, dict):
    fail(f"[fatal] {src} is not a JSON object (top-level must be {{...}})")
permissions = data.get("permissions", {})
if not isinstance(permissions, dict):
    fail(f"[fatal] {src} has 'permissions' but it is not a JSON object (got {type(permissions).__name__})")
env = data.get("env", {})
if not isinstance(env, dict):
    fail(f"[fatal] {src} has 'env' but it is not a JSON object (got {type(env).__name__})")

# Each managed key on its own: absent, the wanted value, or the value the
# previous revision wrote. A file can hold a mix -- /model writes the model key
# alone -- and is upgraded key by key. Any other value is a hand edit.
def previous_value(have, previous, key):
    return key in have and key in previous and same(have[key], previous[key])


conflicts = [f"  {k}: have {data[k]!r}, want {v!r}"
             for k, v in WANT.items()
             if k in data and not same(data[k], v) and not previous_value(data, PREVIOUS, k)]
conflicts += [f"  permissions.{k}: have {permissions[k]!r}, want {v!r}"
              for k, v in WANT_PERMISSIONS.items()
              if k in permissions and not same(permissions[k], v)]
conflicts += [f"  env.{k}: have {env[k]!r}, want {v!r}"
              for k, v in WANT_ENV.items()
              if k in env and not same(env[k], v) and not previous_value(env, PREVIOUS_ENV, k)]
if conflicts:
    fail(f"[fatal] existing values in {src} differ from what this script wants:",
         *conflicts,
         "Refusing to overwrite. To proceed: open the file by hand,",
         "either change the values to the wanted ones or delete the",
         "conflicting keys, then re-run this script.")
if holds(data, WANT) and holds(permissions, WANT_PERMISSIONS) and holds(env, WANT_ENV):
    state = "current"
elif (any(previous_value(data, PREVIOUS, k) and not same(data[k], v) for k, v in WANT.items())
        or any(previous_value(env, PREVIOUS_ENV, k) and not same(env[k], v) for k, v in WANT_ENV.items())):
    state = "previous"
else:
    state = "missing"

print(state)
if mode == "write":
    data.update(WANT)
    permissions.update(WANT_PERMISSIONS)
    data["permissions"] = permissions
    env.update(WANT_ENV)
    data["env"] = env
    with open(sys.argv[3], "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PYEOF
}

# Prints the CLAUDE.md state: absent or current. Dies on anything else.
claudemd_state() {
    if [ ! -e "$CLAUDEMD" ] && [ ! -L "$CLAUDEMD" ]; then
        echo absent
        return
    fi
    [ -f "$CLAUDEMD" ] || die "$CLAUDEMD exists but is not a regular file — refusing to touch"
    # Byte-exact compare: $(cat ...) would strip trailing newlines.
    printf '%s' "$CLAUDEMD_CONTENT" | cmp -s - "$CLAUDEMD" \
        || die "$(printf 'FATAL: %s already exists with different content.\nRefusing to overwrite. If the existing content is your own customization,\nleave it. If it is stale and you want this script to manage it again,\ndelete the file and re-run.' "$CLAUDEMD")"
    echo current
}

# ---------------------------------------------------------------------------
# (0) check every managed item before changing anything
# ---------------------------------------------------------------------------
#
# A refusal here leaves the machine as it was, binary included. Each write step
# below decides again from the file as it is at that moment.

section "(0) check existing configuration"

BLOCK_STATE="$(bashrc_block_state)"
info "$BASHRC env block: $BLOCK_STATE"
SETTINGS_STATE="$(settings_merge check "$SETTINGS")"
info "$SETTINGS managed keys: $SETTINGS_STATE"
CLAUDEMD_STATE="$(claudemd_state)"
info "$CLAUDEMD: $CLAUDEMD_STATE"

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

section "(a) install/update Claude Code via $INSTALLER_URL"

if [ -e "$CLAUDE_BIN" ]; then
    [ -x "$CLAUDE_BIN" ] || die "$CLAUDE_BIN exists but is not executable — refusing to touch it"
fi
info "downloading and running $INSTALLER_URL (latest channel)"
curl -fsSL "$INSTALLER_URL" | bash
[ -x "$CLAUDE_BIN" ] \
    || die "after running installer, $CLAUDE_BIN does not exist or is not executable — installer must have failed"

# Run --version via full path; we have not yet confirmed PATH includes ~/.local/bin
# in this shell (that's step (b) below).
VER_LINE="$("$CLAUDE_BIN" --version 2>&1 | head -1 || true)"
[ -n "$VER_LINE" ] || die "'$CLAUDE_BIN --version' produced no output"
info "claude --version: $VER_LINE"
CLAUDE_VERSION="${VER_LINE%% *}"
[[ "$CLAUDE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "cannot parse Claude Code version from '$VER_LINE'"
dpkg --compare-versions "$CLAUDE_VERSION" ge 2.1.280 \
    || die "Opus 5.5 requires Claude Code 2.1.280 or later, got $CLAUDE_VERSION"

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

section "(c) Claude Code env block in $BASHRC"

BLOCK_STATE="$(bashrc_block_state)"
case "$BLOCK_STATE" in
    current)
        info "Claude Code env block already present and matches expected content — no change"
        ;;
    previous)
        info "replacing the previous revision's Claude Code env block in place"
        replace_previous_block
        ;;
    absent)
        info "appending Claude Code env block to $BASHRC"
        {
            printf '\n'
            printf '%s\n' "$EXPECTED_BLOCK"
        } >> "$BASHRC"
        ;;
    *)
        die "unexpected Claude Code env block state '$BLOCK_STATE'"
        ;;
esac
[ "$(bashrc_block_state)" = current ] \
    || die "$BASHRC Claude Code env block does not match the expected content after writing it"

# ---------------------------------------------------------------------------
# (d) merge managed keys into ~/.claude/settings.json
# ---------------------------------------------------------------------------
#
# Managed keys (top-level):
#     model                  = "claude-opus-5-5[1m]"
#     effortLevel            = "xhigh"          (also applies to older models)
#     showThinkingSummaries  = true             (Opus 5.5 thinks by default;
#                                                show a summary of that thinking)
#     skipDangerousModePermissionPrompt = true  (skip bypass-permissions confirmation)
#     switchModelsOnFlag     = false            (never auto-switch to fallback model)
#     feedbackDrafts         = "off"            (disable SendFeedback tool / transcript drafts)
#     feedbackSurveyRate     = 0                (disable session quality surveys)
#     spinnerTipsEnabled     = false            (disable spinner tips)
#
# Managed keys (under permissions):
#     permissions.defaultMode = "bypassPermissions"
#
# Managed keys (under env): duplicates of the bashrc exports, so any
# launch path that doesn't source .bashrc (GNOME/KDE desktop launchers,
# IDE-integrated terminals) still gets Extra-high effort and privacy settings.
#     env.CLAUDE_CODE_EFFORT_LEVEL         = "xhigh"
#     env.CLAUDE_CODE_SUBAGENT_MODEL       = "claude-opus-5-5[1m]"
#     env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE = "1"
#     env.CLAUDE_CODE_MAX_OUTPUT_TOKENS    = "128000"
#     env.DISABLE_ERROR_REPORTING          = "1"
#     env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1"
#     env.DISABLE_FEEDBACK_COMMAND         = "1"
#
# Behavior on re-run: each managed key is checked individually. If absent
# we set it; if present with the right value we leave it alone; if
# present with the previous revision's value we upgrade it; if present
# with any other value the script aborts with a precise diagnostic (see
# settings_merge). Unmanaged keys (yours: theme, tui, enabledPlugins,
# anything else you've added) are preserved untouched.

section "(d) merge managed keys into $SETTINGS"

mkdir -p "$CLAUDE_DIR"
SETTINGS_STATE="$(settings_merge check "$SETTINGS")"
if [ "$SETTINGS_STATE" = current ]; then
    info "$SETTINGS managed keys already match — no change"
else
    if [ ! -e "$SETTINGS" ]; then
        info "$SETTINGS does not exist — initializing with empty object"
        printf '{}\n' > "$SETTINGS"
    fi
    [ -f "$SETTINGS" ] || die "$SETTINGS exists but is not a regular file"

    # Compute the merged result via python3 (jq is not guaranteed at this
    # stage of the install). Tempfile + atomic rename so a SIGINT mid-write
    # can't corrupt the file; the tempfile takes the original's mode.
    TMP_SETTINGS="$(mktemp "${SETTINGS}.new.XXXXXX")"
    trap 'rm -f -- "$TMP_SETTINGS"' EXIT
    chmod --reference="$SETTINGS" -- "$TMP_SETTINGS"
    SETTINGS_STATE="$(settings_merge write "$SETTINGS" "$TMP_SETTINGS")"
    info "managed keys were: $SETTINGS_STATE"
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$TMP_SETTINGS" \
        || die "merged settings.json failed to re-parse — refusing to install it; original $SETTINGS untouched"
    mv -- "$TMP_SETTINGS" "$SETTINGS"
    trap - EXIT
fi
[ "$(settings_merge check "$SETTINGS")" = current ] \
    || die "$SETTINGS managed keys do not match the expected values after writing it"

info "$SETTINGS now contains:"
cat -- "$SETTINGS"

# ---------------------------------------------------------------------------
# (e) ~/.claude/CLAUDE.md adaptive-thinking nudge
# ---------------------------------------------------------------------------
#
# Opus 5.5 always uses adaptive reasoning — there is no API switch to force
# fixed-large thinking. The only documented way to bias the per-turn
# adaptive trigger upward is system-prompt / CLAUDE.md guidance:
# https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking

section "(e) create $CLAUDEMD"

CLAUDEMD_STATE="$(claudemd_state)"
if [ "$CLAUDEMD_STATE" = current ]; then
    info "$CLAUDEMD already present and matches expected content — no change"
else
    printf '%s' "$CLAUDEMD_CONTENT" > "$CLAUDEMD"
    info "created $CLAUDEMD"
fi
[ "$(claudemd_state)" = current ] \
    || die "$CLAUDEMD does not match the expected content after writing it"

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------

section "success — Claude Code installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so the new env block takes effect."
info "Then run 'claude' and walk through the authentication flow on first launch."
info "Inside a session, verify Extra-high effort with the '/effort' slash command."
