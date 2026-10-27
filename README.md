# gp-autoconnect

Keeps the C-DOT GlobalProtect VPN (`cgp.cdot.in`) connected on Linux. When the
session expires, the network drops, or the server disconnects you, it logs back
in on its own, including answering the OTP prompt.

It runs as a `systemd` service built on
[`openconnect`](https://www.infradead.org/openconnect/). The official
GlobalProtect client is used underneath only for its HIP host-check script; the
connection itself is handled by openconnect, because the official Linux client
has no working command-line connect and won't reconnect through MFA unattended.

Tested on Ubuntu 22.04. It should work on other recent Debian and Ubuntu
versions, but I haven't tried them.

## Before you install: what the MFA automation costs you

This tool keeps your VPN password and your authenticator (OTP) secret together
in one root-only file and generates the 6-digit codes itself. That is the whole
trick that lets it reconnect without you.

The cost is real: anyone who gets root on this computer can then log in to the
VPN as you, without your phone. That removes most of what MFA is there to
protect. Install it only on a machine you trust, and check whether your
workplace allows it. If that trade-off bothers you, stay with the official
GlobalProtect client.

## Install

```bash
git clone https://github.com/melchiaaronzedek/gp-autoconnect.git
cd gp-autoconnect
sudo ./install.sh
```

The installer walks through five steps:

1. Installs anything missing (`openconnect`, `python3`, `zbar-tools`, `poppler-utils`).
2. Asks for your GlobalProtect username and password.
3. Asks for the MFA QR code file that C-DOT IT emailed you (Part 2 of their MFA
   guide). Give its path, for example `~/Downloads/qr.pdf`. PNG, JPG, and PDF all
   work. Scan the same QR with Google or Microsoft Authenticator on your phone
   as well, so you keep a backup.
4. Prints the code it just generated. Check that it matches your phone.
5. Turns off the official client and connects.

After that it connects at boot and reconnects by itself. Your details go to
`/etc/gp-autoconnect/creds`, which only root can read, and never leave the
machine.

## Everyday commands

| What you want | Command |
|---|---|
| Connect | `sudo systemctl start gp-autoconnect` |
| Disconnect | `sudo systemctl stop gp-autoconnect` |
| Reconnect now | `sudo systemctl restart gp-autoconnect` |
| See if it's connected | `systemctl status gp-autoconnect` |
| Show the VPN IP | `ip -br addr show gpoc0` |
| Watch the log live | `journalctl -u gp-autoconnect -f` |
| Stop it starting at boot | `sudo systemctl disable --now gp-autoconnect` |
| Start at boot again | `sudo systemctl enable --now gp-autoconnect` |

In the log, a good login reads `Login OK` followed by `Configured as <ip>`.

## Changing your details

Run these from the cloned folder:

```bash
sudo ./install.sh --reset-creds   # new password (re-enters everything)
sudo ./install.sh --reset-otp     # new QR code only
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This restores the official client. Log out and back in to get its tray icon
back.

## How it works

`gp-login.py` does the login. It sends your username and password, then answers
the OTP challenge with a TOTP code it computes from your saved secret (Python
standard library only), and prints the session cookie.

`gp-autoconnect.sh` waits for the network, runs `gp-login.py`, and feeds the
cookie to `openconnect`, which holds the tunnel on interface `gpoc0`.

`gp-autoconnect.service` is a `systemd` unit with `Restart=always`, so whenever
openconnect exits it logs in again about 20 seconds later. A rejected login
waits 5 minutes before the next try, so a wrong password can't hammer the server
and lock your account. The script also never reuses an OTP time-step twice,
since the server rejects a replayed code.

## When something goes wrong

`Login rejected` in the log usually means a wrong password (fix with
`--reset-creds`) or a machine clock that has drifted, since the codes are
time-based. Correct the clock with `sudo timedatectl set-ntp true`.

Connecting and then dropping every 20 seconds or so is almost always a leftover
tunnel from the official client. Run `sudo ./uninstall.sh`, then
`sudo ./install.sh` again to clear it.

`No authenticator QR code found` means the file wasn't a QR image the reader
could decode. Try the PNG version, or re-run and paste the secret key by hand
instead.

## Files it installs

```
/usr/local/bin/gp-autoconnect.sh
/usr/local/lib/gp-autoconnect/gp-login.py
/etc/systemd/system/gp-autoconnect.service
/etc/gp-autoconnect/creds          # root-only: username, password, OTP secret
```

## License

MIT. See [LICENSE](LICENSE).
