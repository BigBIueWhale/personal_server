# VMware Host-Guest Integration

This folder contains fixes for VMware Workstation Pro host-guest integration issues on Linux (particularly Wayland).

---

## Clipboard Sync (Wayland Host)

VMware Workstation Pro 17.x has broken clipboard sync on Wayland — copying from host to guest doesn't work due to a Mutter bug in Wayland-to-XWayland clipboard synchronization.

See **[fix_vmware_clipboard.md](./fix_vmware_clipboard.md)** for full details.

### Installation (run on HOST)

1. Install build dependencies:
   ```bash
   sudo apt update
   sudo apt install -y cargo rustc libxcb1-dev libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev
   ```

2. Clone and build clipboard-sync:
   ```bash
   cd ~/Downloads
   git clone https://github.com/dnut/clipboard-sync.git
   cd clipboard-sync
   cargo build --release
   ```

3. Copy the installer script into the build directory and run it:
   ```bash
   cp ~/Desktop/personal_server/vmware/install_clipboard_sync.sh .
   ./install_clipboard_sync.sh
   ```

4. Verify:
   ```bash
   systemctl --user status clipboard-sync.service
   ```

---

## Shared Folders

Mount VMware shared folders and create a convenient symlink in your home directory.

### Setup (run on HOST)

In VMware Workstation: VM → Settings → Options → Shared Folders → Add a folder named `shared_vm` pointing to a folder on your host machine.

### Installation (run on GUEST)

```bash
sudo ./mount_vmware_share.sh
```

Script: [mount_vmware_share.sh](./mount_vmware_share.sh)

This script:
1. Creates the mount point at `/mnt/hgfs/shared_vm`
2. Adds an fstab entry for automatic mounting at boot
3. Creates a symlink at `~/shared_vm` for easy access
