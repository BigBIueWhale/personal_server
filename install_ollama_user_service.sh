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

# Persisted, user-editable environment (won't be overwritten on future runs)
CFG_DIR="$HOME/.config/ollama"
ENV_FILE="$CFG_DIR/env"
mkdir -p "$CFG_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# Environment for the user ollama.service
# Bind address for the API (localhost by default). Change to 0.0.0.0:11434 to expose on LAN.
OLLAMA_HOST=127.0.0.1:11434

# How long to keep models loaded (-1=forever, 0=unload immediately, or durations like 30m, 12h).
# Leave commented to use server default (currently ~5m).
# OLLAMA_KEEP_ALIVE=30m

# Optional knobs:
# OLLAMA_MAX_LOADED_MODELS=1
# OLLAMA_MAX_QUEUE=512
# OLLAMA_NUM_PARALLEL=1
# OLLAMA_ORIGINS=*
# OLLAMA_MODELS=$HOME/.ollama
EOF
fi

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
echo "✔ Installed user service pointing at: $BIN"
echo "• Edit env here: $ENV_FILE (then: systemctl --user restart ollama)"
echo "• Manage with:   systemctl --user status|restart|stop ollama"
echo
systemctl --user --no-pager --full status ollama.service || true
