#!/usr/bin/env bash
# scripts/00_install_antigravity_cli.sh — install Google Antigravity CLI (agy)
# and configure high-autonomy, high-reasoning defaults for Gemini 4 Argon (High).
#
# WHAT IT DOES (in order; each step is idempotent — see CONFIGURATION SAFETY)
# ---------------------------------------------------------------------------
#   (0) Check: every managed item in (b)-(d) is checked before anything is
#       changed, so a refusal leaves the machine as it was.
#   (a) Install/update: if /home/<user>/.local/bin/agy is absent, run Google's
#       official bootstrapper (https://antigravity.google/cli/install.sh), which
#       fetches the platform release manifest, SHA-512-verifies the archive, and
#       installs /home/<user>/.local/bin/agy. If the binary is already installed,
#       run `agy update` to update in place on the latest channel, then verify
#       version >= 1.3.5.
#   (b) PATH: ensure /home/<user>/.local/bin is on PATH in /home/<user>/.bashrc
#       via `agy install` (which appends its canonical 2-line PATH snippet if
#       not already present).
#   (c) settings.json: merge the seven persistent managed keys into
#       /home/<user>/.gemini/antigravity-cli/settings.json (plus the one-shot
#       `enableTelemetry: false` override that `agy` syncs to the account
#       backend on startup and then strips via its sparse marshaler) and verify
#       that default-false keys (`enableTerminalSandbox`, `useG1Credits`) are
#       not enabled. Pre-existing unmanaged keys (such as `trustedWorkspaces`)
#       are preserved untouched. If any managed key holds a conflicting value,
#       the script REFUSES.
#   (d) AGENTS.md: create /home/<user>/.gemini/config/AGENTS.md with the
#       multi-step reasoning prompt loaded by `agy` as `<RULE[user_global]>`.
#       If the file already exists with different content, the script REFUSES.
#
# CONFIGURATION SAFETY (by design — re-running this script is safe)
# -----------------------------------------------------------------
#   - On every startup, `agy` parses ~/.gemini/antigravity-cli/settings.json
#     and compares the file against `CliSetting.MarshalSparse()`. Keys equal to
#     `DefaultCliSetting()` (`enableTerminalSandbox: false`, `useG1Credits:
#     false`) and the server-synced `enableTelemetry` override are omitted by
#     `MarshalSparse()`; when `enableTelemetry: false` is present in
#     settings.json, `agy` pushes `SetTelemetryEnabled(false)` to the user's
#     account on Google's backend during startup and rewrites settings.json
#     with the seven non-default managed keys sorted alphabetically.
#   - settings.json is therefore considered `current` when all seven persistent
#     managed keys hold their exact wanted values, `enableTelemetry` is either
#     `false` (awaiting first authenticated startup sync) or absent (already
#     synced and stripped by `MarshalSparse()`), and `enableTerminalSandbox` /
#     `useG1Credits` are absent. Any other value on any of these ten keys causes
#     a loud refusal before anything is modified.
#   - Unmanaged keys (e.g. `trustedWorkspaces`) are preserved untouched.
#   - AGENTS.md is created only if absent; if it exists with our exact 335
#     bytes, no-op; if it exists with anything else, fatal.
#
# RUN AS THE DESKTOP USER (NOT sudo)
# ----------------------------------
# Antigravity CLI installs into /home/<user>/.local/bin/agy and stores config
# under /home/<user>/.gemini/. Running as root would land everything in /root/.
# The script enforces this with require_non_root.
#
# Usage:
#   bash scripts/00_install_antigravity_cli.sh
#
# After it finishes, open a new shell (or `source ~/.bashrc`) so PATH updates
# take effect, then run `agy`.

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

LOCAL_BIN="$TARGET_HOME/.local/bin"
AGY_BIN="$LOCAL_BIN/agy"
GEMINI_DIR="$TARGET_HOME/.gemini"
AGY_DIR="$GEMINI_DIR/antigravity-cli"
SETTINGS="$AGY_DIR/settings.json"
CONFIG_DIR="$GEMINI_DIR/config"
AGENTSMD="$CONFIG_DIR/AGENTS.md"
INSTALLER_URL="https://antigravity.google/cli/install.sh"

if command -v agy >/dev/null 2>&1; then
    FOUND_AGY="$(command -v agy)"
    if [ "$FOUND_AGY" != "$AGY_BIN" ]; then
        die "found agy at '$FOUND_AGY', but this installer manages '$AGY_BIN' — refusing to shadow or replace a different Antigravity CLI install"
    fi
fi

# ---------------------------------------------------------------------------
# Managed configuration
# ---------------------------------------------------------------------------
#
# Persistent non-default keys in ~/.gemini/antigravity-cli/settings.json:
#   allowNonWorkspaceAccess = true
#       Allow file/directory tools to access paths outside the active workspace
#       without interactive confirmation prompts.
#   artifactReviewPolicy    = "always-proceed"
#       Never block execution waiting for manual approval on artifact plans.
#   model                   = "Gemini 4 Argon (High)"
#       Pin Gemini 4 Argon at High thinking effort (`gemini-4-argon-high`).
#   showFeedbackSurvey      = false
#       Disable in-session feedback survey prompts.
#   showTips                = false
#       Disable startup and UI tip banners.
#   toolPermission          = "always-proceed"
#       Auto-approve tool execution (commands, edits) without permission prompts.
#   verbosity               = "high"
#       Display full thinking summaries and tool outputs in the UI.
#
# Sparse / server-synced boolean keys whose desired value is false:
#   enableTelemetry         = false (written on install; synced to the account
#                             backend by `agy` on startup and then stripped by
#                             `CliSetting.MarshalSparse()`)
#   enableTerminalSandbox   = false (default in `DefaultCliSetting()`; omitted
#                             by `MarshalSparse()`)
#   useG1Credits            = false (default in `DefaultCliSetting()`; omitted
#                             by `MarshalSparse()`)

AGENTSMD_CONTENT='This account'\''s work usually involves subtle infrastructure and
system-config tasks where wrong answers are expensive. Multi-step
reasoning is expected for any non-trivial change. Think carefully
before committing to a plan or making file edits. Verify assumptions
against actual file contents rather than memory of "typical" patterns.
'

# Prints the .bashrc Antigravity PATH snippet state: absent or current.
# Dies if the marker comment appears more than once or with unexpected lines.
bashrc_path_state() {
    python3 - "$BASHRC" "$TARGET_HOME" <<'PYEOF'
import sys

bashrc_path, target_home = sys.argv[1], sys.argv[2]
with open(bashrc_path, encoding="utf-8") as f:
    text = f.read()

marker = "# Added by Antigravity CLI installer"
expected_block = (
    "\n\n"
    "# Added by Antigravity CLI installer\n"
    f'export PATH="{target_home}/.local/bin:$PATH"\n'
)

n_marker = text.count(marker)
n_block = text.count(expected_block)

if n_marker == 0 and n_block == 0:
    print("absent")
elif n_marker == 1 and n_block == 1:
    print("current")
else:
    print(
        f"[fatal] {bashrc_path}: unexpected Antigravity CLI PATH block state "
        f"(marker count={n_marker}, exact block count={n_block}); refusing to touch",
        file=sys.stderr,
    )
    sys.exit(2)
PYEOF
}

# Decides the settings.json merge and, in write mode, writes the merged result
# to DEST. Prints the state it found: current or missing. Exits 2, naming every
# conflict, if any managed or default-false key holds a conflicting value.
#   settings_merge check SETTINGS
#   settings_merge write SETTINGS DEST
settings_merge() {
    python3 - "$@" <<'PYEOF'
import json
import os
import sys

mode, src = sys.argv[1], sys.argv[2]

WANT = {
    "allowNonWorkspaceAccess": True,
    "artifactReviewPolicy": "always-proceed",
    "model": "Gemini 4 Argon (High)",
    "showFeedbackSurvey": False,
    "showTips": False,
    "toolPermission": "always-proceed",
    "verbosity": "high",
}

# Keys whose wanted value is False and which agy's MarshalSparse() omits when
# rewriting settings.json on startup. enableTelemetry is additionally synced to
# the account server via syncTelemetryFromServer() when present as False.
SPARSE_FALSE_KEYS = (
    "enableTelemetry",
    "enableTerminalSandbox",
    "useG1Credits",
)


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
    if not os.path.isfile(src) or os.path.islink(src):
        fail(f"[fatal] {src} exists but is not a regular file")
    try:
        with open(src, encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        fail(f"[fatal] {src} is not valid JSON: {e}")
if not isinstance(data, dict):
    fail(f"[fatal] {src} is not a JSON object (top-level must be {{...}})")

conflicts = [
    f"  {k}: have {data[k]!r}, want {v!r}"
    for k, v in WANT.items()
    if k in data and not same(data[k], v)
]
conflicts += [
    f"  {k}: have {data[k]!r}, want False (or absent)"
    for k in SPARSE_FALSE_KEYS
    if k in data and not same(data[k], False)
]
if conflicts:
    fail(
        f"[fatal] existing values in {src} differ from what this script wants:",
        *conflicts,
        "Refusing to overwrite. To proceed: open the file by hand,",
        "either change the values to the wanted ones or delete the",
        "conflicting keys, then re-run this script.",
    )

# settings.json is current when all 7 persistent WANT keys match,
# enableTerminalSandbox and useG1Credits are absent (their MarshalSparse form),
# and enableTelemetry is either False (awaiting first agy startup sync) or
# absent (already synced and stripped by MarshalSparse).
if (
    holds(data, WANT)
    and "enableTerminalSandbox" not in data
    and "useG1Credits" not in data
):
    state = "current"
else:
    state = "missing"

print(state)
if mode == "write":
    data.update(WANT)
    data["enableTelemetry"] = False
    data.pop("enableTerminalSandbox", None)
    data.pop("useG1Credits", None)
    with open(sys.argv[3], "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
PYEOF
}

# Prints the AGENTS.md state: absent or current. Dies on anything else.
agentsmd_state() {
    if [ ! -e "$AGENTSMD" ] && [ ! -L "$AGENTSMD" ]; then
        echo absent
        return
    fi
    if [ -L "$AGENTSMD" ] || [ ! -f "$AGENTSMD" ]; then
        die "$AGENTSMD exists but is not a regular file — refusing to touch"
    fi
    printf '%s' "$AGENTSMD_CONTENT" | cmp -s - "$AGENTSMD" \
        || die "$(printf 'FATAL: %s already exists with different content.\nRefusing to overwrite. If the existing content is your own customization,\nleave it. If it is stale and you want this script to manage it again,\ndelete the file and re-run.' "$AGENTSMD")"
    echo current
}

# ---------------------------------------------------------------------------
# (0) check every managed item before changing anything
# ---------------------------------------------------------------------------

section "(0) check existing configuration"

PATH_STATE="$(bashrc_path_state)"
info "$BASHRC Antigravity PATH block: $PATH_STATE"
SETTINGS_STATE="$(settings_merge check "$SETTINGS")"
info "$SETTINGS managed keys: $SETTINGS_STATE"
AGENTSMD_STATE="$(agentsmd_state)"
info "$AGENTSMD: $AGENTSMD_STATE"

# ---------------------------------------------------------------------------
# (a) install or update Antigravity CLI
# ---------------------------------------------------------------------------
#
# Upstream's install.sh exits early with a notice if ~/.local/bin/agy already
# exists. Therefore:
#   - Fresh machine (binary absent): run install.sh, which downloads the latest
#     platform archive, verifies its SHA-512 against the release manifest,
#     places ~/.local/bin/agy, and runs `agy install`.
#   - Existing install: verify ~/.local/bin/agy is executable and run
#     `agy update` to update in place against the same release manifest.

section "(a) install/update Antigravity CLI ($AGY_BIN)"

if [ -e "$AGY_BIN" ] || [ -L "$AGY_BIN" ]; then
    [ -f "$AGY_BIN" ] && [ ! -L "$AGY_BIN" ] \
        || die "$AGY_BIN exists but is not a regular file — refusing to touch it"
    [ -x "$AGY_BIN" ] \
        || die "$AGY_BIN exists but is not executable — refusing to touch it"
    info "$AGY_BIN already present — checking for updates via 'agy update'"
    "$AGY_BIN" update
else
    info "downloading and running $INSTALLER_URL (latest channel)"
    curl -fsSL "$INSTALLER_URL" | bash
fi

[ -x "$AGY_BIN" ] \
    || die "after install/update, $AGY_BIN does not exist or is not executable"

VER_LINE="$("$AGY_BIN" --version 2>&1 | head -1 || true)"
[ -n "$VER_LINE" ] || die "'$AGY_BIN --version' produced no output"
info "agy --version: $VER_LINE"
AGY_VERSION="${VER_LINE##* }"
[[ "$AGY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "cannot parse Antigravity CLI version from '$VER_LINE'"
dpkg --compare-versions "$AGY_VERSION" ge 1.3.5 \
    || die "Gemini 4 Argon (High) requires Antigravity CLI 1.3.5 or later, got $AGY_VERSION"

# ---------------------------------------------------------------------------
# (b) ensure ~/.local/bin is on PATH in ~/.bashrc via `agy install`
# ---------------------------------------------------------------------------

section "(b) ~/.local/bin on PATH in $BASHRC"

PATH_STATE="$(bashrc_path_state)"
case "$PATH_STATE" in
    current)
        info "$BASHRC already has the Antigravity CLI installer PATH block — no change"
        ;;
    absent)
        info "running '$AGY_BIN install' to configure PATH in $BASHRC"
        "$AGY_BIN" install
        ;;
    *)
        die "unexpected PATH block state '$PATH_STATE'"
        ;;
esac
[ "$(bashrc_path_state)" = current ] \
    || die "$BASHRC Antigravity CLI PATH block is not in expected state after '$AGY_BIN install'"

# ---------------------------------------------------------------------------
# (c) merge managed keys into ~/.gemini/antigravity-cli/settings.json
# ---------------------------------------------------------------------------

section "(c) merge managed keys into $SETTINGS"

mkdir -p "$AGY_DIR"
SETTINGS_STATE="$(settings_merge check "$SETTINGS")"
if [ "$SETTINGS_STATE" = current ]; then
    info "$SETTINGS managed keys already match — no change"
else
    if [ ! -e "$SETTINGS" ]; then
        info "$SETTINGS does not exist — initializing with empty object"
        printf '{}\n' > "$SETTINGS"
    fi
    [ -f "$SETTINGS" ] && [ ! -L "$SETTINGS" ] \
        || die "$SETTINGS exists but is not a regular file"

    TMP_SETTINGS="$(mktemp "${SETTINGS}.new.XXXXXX")"
    trap 'rm -f -- "$TMP_SETTINGS"' EXIT
    chmod --reference="$SETTINGS" -- "$TMP_SETTINGS"
    SETTINGS_STATE="$(settings_merge write "$SETTINGS" "$TMP_SETTINGS")"
    info "managed keys were: $SETTINGS_STATE"
    python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$TMP_SETTINGS" \
        || die "merged settings.json failed to re-parse — refusing to install it; original $SETTINGS untouched"
    mv -- "$TMP_SETTINGS" "$SETTINGS"
    trap - EXIT
    info "updated managed keys in $SETTINGS"
fi
[ "$(settings_merge check "$SETTINGS")" = current ] \
    || die "$SETTINGS managed keys do not match the expected values after writing it"

# ---------------------------------------------------------------------------
# (d) ~/.gemini/config/AGENTS.md multi-step reasoning prompt
# ---------------------------------------------------------------------------

section "(d) create $AGENTSMD"

mkdir -p "$CONFIG_DIR"
AGENTSMD_STATE="$(agentsmd_state)"
if [ "$AGENTSMD_STATE" = current ]; then
    info "$AGENTSMD already present and matches expected content — no change"
else
    TMP_AGENTSMD="$(mktemp "${AGENTSMD}.new.XXXXXX")"
    trap 'rm -f -- "$TMP_AGENTSMD"' EXIT
    chmod 0644 -- "$TMP_AGENTSMD"
    printf '%s' "$AGENTSMD_CONTENT" > "$TMP_AGENTSMD"
    mv -- "$TMP_AGENTSMD" "$AGENTSMD"
    trap - EXIT
    info "created $AGENTSMD"
fi
[ "$(agentsmd_state)" = current ] \
    || die "$AGENTSMD does not match the expected content after writing it"

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------

section "success — Antigravity CLI installed and configured"
info "Open a NEW shell (or run 'source ~/.bashrc') so PATH updates take effect."
info "Then run 'agy' and walk through the authentication flow on first launch."
info "Managed defaults: model='Gemini 4 Argon (High)', verbosity=high, toolPermission=always-proceed, artifactReviewPolicy=always-proceed, allowNonWorkspaceAccess=true, showFeedbackSurvey=false, showTips=false, enableTelemetry=false."
