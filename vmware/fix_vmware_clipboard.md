# Fix VMware Workstation Copy/Paste on Ubuntu 24.04 Wayland Host

## The Problem

On Ubuntu 24.04 with Wayland (GNOME), VMware Workstation Pro 17.x clipboard sync is **broken in one direction**:
- **Guest → Host**: Works fine
- **Host → Guest**: Does NOT work

This affects copying text from your host desktop into a VMware guest VM.

## Root Cause

VMware Workstation runs under **XWayland** (X11 compatibility layer), not native Wayland. The clipboard systems don't sync properly:

1. You copy text in a Wayland app (Firefox, terminal, etc.)
2. The Wayland clipboard is set
3. **Mutter should sync Wayland → X11 clipboard** when VMware gets focus
4. This sync is buggy/broken in GNOME Mutter ([Issue #1194](https://gitlab.gnome.org/GNOME/mutter/-/issues/1194), [Issue #3490](https://gitlab.gnome.org/GNOME/mutter/-/issues/3490))
5. VMware can't read the clipboard, so nothing reaches the guest

The reverse direction works because Mutter's X11 → Wayland sync is functional.

## Two Options

### Option A: Patch Mutter (not chosen)

Same approach as the [ubuntu_patch_unattended_access](https://github.com/BigBIueWhale/ubuntu_patch_unattended_access) project:
- Clone Mutter source
- Patch `src/wayland/meta-wayland-data-device.c` to fix the sync
- Build, install, `apt-mark hold mutter`

**Drawback**: Mutter is a core system component. Patching it is more invasive and risky than patching a portal.

### Option B: Userspace Clipboard Sync (chosen)

Use [clipboard-sync](https://github.com/dnut/clipboard-sync) — a standalone Rust tool that:
- Discovers all X11 and Wayland clipboards on the system
- Polls them every ~200ms
- When one changes, syncs to all others

This sidesteps Mutter's buggy built-in sync entirely.

**Why we trust it**:
- 138 GitHub stars, 5 contributors, active since April 2022
- Clean Rust code — no network calls, no file I/O, just clipboard operations
- We build from source (don't use pre-built packages from personal repos)

---

## Installation (Build from Source)

### 1. Install Build Dependencies

```bash
sudo apt update
sudo apt install -y cargo rustc libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev
```

### 2. Clone and Build

```bash
cd ~/Downloads
git clone https://github.com/dnut/clipboard-sync.git
cd clipboard-sync
cargo build --release
```

**Expect**: Build completes with `Finished release [optimized] target(s)`.

### 3. Install

```bash
./install_clipboard_sync.sh
```

Or manually:

```bash
# Create directory and copy binary
mkdir -p ~/.local/opt/clipboard-sync
cp target/release/clipboard-sync ~/.local/opt/clipboard-sync/

# Create systemd user service
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/clipboard-sync.service << 'EOF'
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

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now clipboard-sync.service
```

### 4. Verify

```bash
systemctl --user status clipboard-sync.service
```

**Expect**: `Active: active (running)`.

### 5. Test

1. Copy text in a Wayland app (e.g., Firefox, GNOME Terminal)
2. Switch to VMware Workstation
3. Paste inside the guest VM
4. It should now work in both directions

---

## Troubleshooting

**Service fails to start**:
```bash
journalctl --user -u clipboard-sync.service -f
```

**No clipboards detected**: Ensure you're running a graphical session (not SSH).

**Still doesn't work**: Check that VMware Tools / open-vm-tools-desktop is installed in the guest.

---

## Uninstall

```bash
systemctl --user disable --now clipboard-sync.service
rm -rf ~/.local/opt/clipboard-sync
rm ~/.config/systemd/user/clipboard-sync.service
systemctl --user daemon-reload
```

---

## References

- [clipboard-sync GitHub](https://github.com/dnut/clipboard-sync)
- [Mutter Issue #1194 – Clipboard only works in one direction](https://gitlab.gnome.org/GNOME/mutter/-/issues/1194)
- [Mutter Issue #3490 – 46.1 clipboard regression](https://gitlab.gnome.org/GNOME/mutter/-/issues/3490)
- [Martin Gräßlin's blog – Synchronizing X11 and Wayland clipboard](https://blog.martin-graesslin.com/blog/2016/07/synchronizing-the-x11-and-wayland-clipboard/)
