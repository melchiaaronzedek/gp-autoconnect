#!/bin/bash
# Run with: sudo ./uninstall.sh   — removes auto-reconnect and restores the official client.
set -u
[ "$EUID" -ne 0 ] && { echo "Run with sudo" >&2; exit 1; }
REAL_USER=${SUDO_USER:-}

systemctl disable --now gp-autoconnect.service 2>/dev/null
rm -f /etc/systemd/system/gp-autoconnect.service /usr/local/bin/gp-autoconnect.sh
rm -rf /usr/local/lib/gp-autoconnect /run/gp-autoconnect
rm -rf /etc/gp-autoconnect
systemctl daemon-reload

systemctl enable --now gpd.service
if [ -n "$REAL_USER" ]; then
    RUID=$(id -u "$REAL_USER")
    rm -f "/home/$REAL_USER/.config/autostart/PanGPUI.desktop"
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR=/run/user/$RUID systemctl --user enable --now gpa.service
fi
echo "Removed. Official GlobalProtect restored (log out/in to get the tray icon back)."
