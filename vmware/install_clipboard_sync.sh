#!/usr/bin/env bash
set -Eeuo pipefail

# Installer for clipboard-sync user service.
# Syncs X11 and Wayland clipboards to fix VMware Workstation copy/paste on Wayland hosts.
#
# Run from the clipboard-sync repo root after building:
#   cargo build --release
#   ./install_clipboard_sync.sh

BIN="$PWD/target/release/clipboard-sync"
if [[ ! -x "$BIN" ]]; then
  echo "Error: couldn't find executable '$BIN'."
  echo "Make sure you've built the project first:"
  echo "  cargo build --release"
  exit 1
fi

# Fixed location we'll point the service to
DEST_DIR="$HOME/.local/opt/clipboard-sync"
mkdir -p "$DEST_DIR"
cp "$BIN" "$DEST_DIR/clipboard-sync"
chmod +x "$DEST_DIR/clipboard-sync"

# systemd --user unit
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/clipboard-sync.service"
mkdir -p "$UNIT_DIR"

cat >"$UNIT_FILE" <<'EOF'
[Unit]
Description=Clipboard Sync – X11/Wayland clipboard synchronization
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.local/opt/clipboard-sync/clipboard-sync --hide-timestamp
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

# Reload unit files and (re)start
systemctl --user daemon-reload
systemctl --user enable clipboard-sync.service
systemctl --user restart clipboard-sync.service

echo
echo "✔ Installed clipboard-sync user service"
echo "• Binary:  $DEST_DIR/clipboard-sync"
echo "• Service: $UNIT_FILE"
echo "• Manage:  systemctl --user status|restart|stop clipboard-sync"
echo
systemctl --user --no-pager --full status clipboard-sync.service || true
