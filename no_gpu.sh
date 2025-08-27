#!/usr/bin/env bash
set -euo pipefail

APP=rustdesk
SRC="/usr/share/applications/${APP}.desktop"
DEST="${HOME}/.local/share/applications/${APP}.desktop"
BACKUP="${DEST}.bak"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; fi

# Preflight
[[ -f "$SRC" ]] || { echo "Source not found: $SRC"; exit 1; }
mkdir -p "$(dirname "$DEST")"

# Create user override if missing
if [[ ! -f "$DEST" ]]; then
  install -Dm644 "$SRC" "$DEST"
fi

# Refuse if backup already exists (unless --force)
if [[ -f "$BACKUP" && $FORCE -ne 1 ]]; then
  echo "Refusing: backup already exists at $BACKUP"
  echo "If you really want to proceed, rerun with --force (it will rotate the old backup)."
  exit 2
fi

# Make/rotate backup
if [[ -f "$BACKUP" && $FORCE -eq 1 ]]; then
  mv "$BACKUP" "$BACKUP.$(date +%s)"
fi
cp -f "$DEST" "$BACKUP"

# Patch Exec= lines idempotently
PREFIX='env DRI_PRIME=0 __NV_PRIME_RENDER_OFFLOAD=0 __GLX_VENDOR_LIBRARY_NAME=mesa '
tmp="$(mktemp)"
awk -v prefix="$PREFIX" '
  /^Exec=/ {
    line=$0; sub(/^Exec=/,"",line);
    if (line !~ "^"prefix) {
      print "Exec=" prefix line;
    } else {
      print $0;
    }
    next
  }
  { print }
' "$DEST" > "$tmp"
mv "$tmp" "$DEST"

# Validate & refresh caches (non-fatal if missing)
desktop-file-validate "$DEST" || true
update-desktop-database "${HOME}/.local/share/applications" || true

echo "Patched: $DEST"
grep -n '^Exec=' "$DEST"
echo "Backup:  $BACKUP"
