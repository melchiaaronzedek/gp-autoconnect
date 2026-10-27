#!/bin/bash
# GlobalProtect auto-reconnect installer.
#   sudo ./install.sh              first install, or fix a broken one
#   sudo ./install.sh --reset-creds   change username / password / QR
#   sudo ./install.sh --reset-otp     change only the MFA QR code
set -euo pipefail
cd "$(dirname "$0")"

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo ./install.sh" >&2
    exit 1
fi
REAL_USER=${SUDO_USER:-}
MODE=${1:-}

# --- dependencies ---------------------------------------------------------
need=()
command -v openconnect >/dev/null || need+=(openconnect)
command -v python3     >/dev/null || need+=(python3)
command -v zbarimg     >/dev/null || need+=(zbar-tools)      # read the QR image
command -v pdftoppm    >/dev/null || need+=(poppler-utils)   # QR delivered as a PDF
[ -f /usr/share/vpnc-scripts/vpnc-script ] || need+=(vpnc-scripts)
if [ ${#need[@]} -gt 0 ]; then
    echo "Installing required packages: ${need[*]}"
    apt-get update -qq
    apt-get install -y "${need[@]}"
fi

mkdir -p /etc/gp-autoconnect
chmod 700 /etc/gp-autoconnect

CREDS=/etc/gp-autoconnect/creds
umask 077
U=$(sed -n 1p "$CREDS" 2>/dev/null || true)
P=$(sed -n 2p "$CREDS" 2>/dev/null || true)
T=$(sed -n 3p "$CREDS" 2>/dev/null || true)

if [ -z "$U" ] || [ -z "$P" ] || [ "$MODE" = "--reset-creds" ]; then
    read -rp  "GlobalProtect username: " U
    read -rsp "GlobalProtect password: " P; echo
fi

if [ -z "$T" ] || [ "$MODE" = "--reset-creds" ] || [ "$MODE" = "--reset-otp" ]; then
    echo "MFA setup: give the path of the QR code file from the email (PNG/JPG/PDF),"
    echo "or leave empty to paste the secret key instead."
    read -rp "QR code file: " QR
    QR=${QR/#\~/${SUDO_USER:+/home/$SUDO_USER}}
    QR=${QR//\'/}; QR=${QR//\"/}
    if [ -n "$QR" ]; then
        [ -f "$QR" ] || { echo "File not found: $QR" >&2; exit 1; }
        TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
        case "${QR,,}" in
            *.pdf) pdftoppm -r 200 -png "$QR" "$TMPD/page" ;;
            *)     cp "$QR" "$TMPD/" ;;
        esac
        T=$(zbarimg --raw -q "$TMPD"/* 2>/dev/null | grep -m1 '^otpauth://' || true)
        [ -n "$T" ] || { echo "No authenticator QR code found in $QR" >&2; exit 1; }
    else
        read -rsp "Secret key (hidden): " T; echo
    fi
fi

printf '%s\n%s\n%s\n' "$U" "$P" "$T" > "$CREDS"
unset P T
chown root:root "$CREDS"
chmod 600 "$CREDS"

install -d -m 755 /usr/local/lib/gp-autoconnect
install -m 755 gp-login.py /usr/local/lib/gp-autoconnect/gp-login.py

echo -n "Check: OTP generated on this machine right now = "
/usr/bin/python3 -I - "$CREDS" <<'EOF'
import importlib.util, sys, time
s = importlib.util.spec_from_file_location("g", "/usr/local/lib/gp-autoconnect/gp-login.py")
g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
k, d, p, h = g.parse_totp(open(sys.argv[1]).read().splitlines()[2].strip())
print(g.totp(k, d, p, h, int(time.time()) // p), "<- should match your phone's authenticator app")
EOF

install -m 755 gp-autoconnect.sh /usr/local/bin/gp-autoconnect.sh
install -m 644 gp-autoconnect.service /etc/systemd/system/gp-autoconnect.service

# The official client and openconnect can't both own the tunnel: stop the official one.
if systemctl list-unit-files gpd.service >/dev/null 2>&1; then
    echo "Stopping official GlobalProtect client..."
    systemctl disable --now gpd.service 2>/dev/null || true
    if [ -n "$REAL_USER" ]; then
        RUID=$(id -u "$REAL_USER")
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR=/run/user/$RUID systemctl --user disable --now gpa.service 2>/dev/null || true
        AUTO=/home/$REAL_USER/.config/autostart
        sudo -u "$REAL_USER" mkdir -p "$AUTO"
        printf '[Desktop Entry]\nHidden=true\n' | sudo -u "$REAL_USER" tee "$AUTO/PanGPUI.desktop" >/dev/null
    fi
    pkill -f /opt/paloaltonetworks/globalprotect/PanGPUI 2>/dev/null || true
    pkill -f /opt/paloaltonetworks/globalprotect/PanGPA  2>/dev/null || true
    sleep 2
fi

systemctl daemon-reload
systemctl enable gp-autoconnect.service
rm -f /run/gp-autoconnect/last_totp_step
systemctl restart gp-autoconnect.service

echo
echo "Installed and starting. Watching the log for 20s (Ctrl+C to stop watching; VPN keeps running)..."
echo "Look for 'Login OK' then 'Configured as <ip>' = connected."
timeout 20 journalctl -u gp-autoconnect -f -n 0 || true
echo
systemctl --no-pager status gp-autoconnect | head -4
