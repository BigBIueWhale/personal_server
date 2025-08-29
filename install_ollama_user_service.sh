#!/usr/bin/env bash
set -Eeuo pipefail

# Installer for a user-level Ollama service that tracks the CWD 'ollama' binary.

BIN="$PWD/ollama"
if [[ ! -x "$BIN" ]]; then
  echo "Error: couldn't find executable '$BIN'. Run this script from the folder containing the 'ollama' binary."
  exit 1
fi

# Ensure executable bit just in case
chmod +x "$BIN"

# Fixed location we'll point the service to (symlink -> CWD/ollama)
DEST_DIR="$HOME/.local/opt/ollama"
mkdir -p "$DEST_DIR"
ln -sfn "$BIN" "$DEST_DIR/ollama"

# Optional: make 'ollama' CLI available on your PATH
mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST_DIR/ollama" "$HOME/.local/bin/ollama"

# Environment pushed by this installer (OVERWRITTEN on every run).
CFG_DIR="$HOME/.config/ollama"
ENV_FILE="$CFG_DIR/env"
mkdir -p "$CFG_DIR"

# Detect the Docker bridge gateway IP (containers can reach this; not public). Keep it simple.
detect_bridge_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="172.17.0.1"   # sensible default on most Docker installs
  fi
  printf '%s' "$ip"
}

BRIDGE_IP="$(detect_bridge_ip)"

# Write a fresh env file every time (authoritative config).
cat >"$ENV_FILE" <<EOF
# Environment for the user ollama.service
# Bind address for the API (localhost by default). Change to 0.0.0.0:11434 to expose on LAN.
OLLAMA_HOST=${BRIDGE_IP}:11434


# Forever, instead of default 5 minutes
# OLLAMA_KEEP_ALIVE=-1

# Come on, we can't run more than one model at a time
OLLAMA_NUM_PARALLEL=1

# Flash attention takes better advantage of Nvidia GPUs
# Might have negative effect on gemma3 image understanding?
OLLAMA_FLASH_ATTENTION=1

# Works only together with flash attention, enable only if your GPU has 24GB VRAM.
# OLLAMA_KV_CACHE_TYPE=q8_0
EOF

# systemd --user unit
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/ollama.service"
mkdir -p "$UNIT_DIR"

cat >"$UNIT_FILE" <<'EOF'
[Unit]
Description=Ollama (user) – local LLM server
After=network-online.target default.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/ollama/env
ExecStart=%h/.local/opt/ollama/ollama serve
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

# Reload unit files and (re)start
systemctl --user daemon-reload
systemctl --user enable ollama.service
systemctl --user restart ollama.service

echo
echo "✔ Installed/updated user service pointing at: $BIN"
echo "• Pushed env to: $ENV_FILE (OLLAMA_HOST set to ${BRIDGE_IP}:11434)"
echo "• Manage with:   systemctl --user status|restart|stop ollama"
echo
systemctl --user --no-pager --full status ollama.service || true
