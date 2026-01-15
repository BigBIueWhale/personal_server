#!/bin/bash
set -e

SHARE_NAME="shared_vm"
MOUNT_POINT="/mnt/hgfs/$SHARE_NAME"
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
SYMLINK="$USER_HOME/$SHARE_NAME"

# Create mount point
mkdir -p "$MOUNT_POINT"

# Add to fstab if not already there
FSTAB_ENTRY=".host:/$SHARE_NAME $MOUNT_POINT fuse.vmhgfs-fuse allow_other,defaults 0 0"
if ! grep -qF ".host:/$SHARE_NAME" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "Added entry to /etc/fstab"
fi

# Mount via fstab
mount -a

# Create symlink in user's home directory
if [ ! -e "$SYMLINK" ]; then
    ln -s "$MOUNT_POINT" "$SYMLINK"
    chown -h "${SUDO_USER:-$USER}:" "$SYMLINK"
    echo "Created symlink: $SYMLINK"
fi

echo "Done! Shared folder mounted at $MOUNT_POINT"
echo "Symlink available at $SYMLINK"
