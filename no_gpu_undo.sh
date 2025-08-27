# Restore your last backup
cp -f ~/.local/share/applications/rustdesk.desktop.bak \
      ~/.local/share/applications/rustdesk.desktop
update-desktop-database ~/.local/share/applications || true
