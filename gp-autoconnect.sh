#!/bin/bash
# Logs in (password + TOTP) with gp-login.py, then hands the session cookie to openconnect.
# systemd restarts this whenever it exits (session expiry, network drop, server kick),
# giving automatic reconnect.
set -u

CONF=/etc/gp-autoconnect/config
CREDS=/etc/gp-autoconnect/creds   # lines: username, password, TOTP secret/URI (root:root 600)
LOGIN=/usr/local/lib/gp-autoconnect/gp-login.py

SERVER=cgp.cdot.in
[ -f "$CONF" ] && . "$CONF"

HIP=()
[ -x /usr/libexec/openconnect/hipreport.sh ] && HIP=(--csd-wrapper=/usr/libexec/openconnect/hipreport.sh)

# Wait for basic network before trying, so we don't burn logins while offline.
for _ in $(seq 1 30); do
    getent hosts "$SERVER" >/dev/null && break
    sleep 2
done

COOKIE=$(/usr/bin/python3 -I "$LOGIN" "$CREDS" "$SERVER")
rc=$?
if [ $rc -ne 0 ]; then
    # Back off on rejected logins so repeated failures don't lock the account.
    [ $rc -eq 2 ] && { echo "Login rejected; waiting 5 min before retry" >&2; sleep 300; }
    exit 1
fi

exec openconnect \
    --protocol=gp \
    --cookie-on-stdin \
    --non-inter \
    --interface=gpoc0 \
    --reconnect-timeout=60 \
    "${HIP[@]}" \
    "$SERVER" <<< "$COOKIE"
