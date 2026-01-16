# VMware Host-Guest Integration

Scripts for VMware Workstation Pro host-guest integration on Linux.

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
