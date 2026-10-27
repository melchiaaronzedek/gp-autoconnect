#!/usr/bin/python3
"""GlobalProtect gateway login with password + TOTP challenge.

Prints an openconnect-compatible GP cookie on stdout (for --cookie-on-stdin).
Usage: gp-login.py CREDS_FILE SERVER
CREDS_FILE lines: 1 username, 2 password, 3 TOTP secret (base32) or otpauth:// URI.
Exit codes: 0 ok, 2 auth rejected, 3 config error, 4 network/protocol error.
"""
import base64
import hashlib
import hmac
import os
import re
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

STATE = "/run/gp-autoconnect/last_totp_step"

# jnlp <argument> positions saved into the cookie (same as openconnect's gp_login_args)
SAVED_ARGS = {1: "authcookie", 3: "portal", 4: "user", 7: "domain", 15: "preferred-ip", 18: "preferred-ipv6"}
COOKIE_ORDER = ["authcookie", "portal", "user", "domain", "preferred-ip", "preferred-ipv6"]


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def parse_totp(spec):
    """Return (secret_bytes, digits, period, digestmod) from a base32 secret or otpauth URI."""
    digits, period, algo = 6, 30, "SHA1"
    if spec.startswith("otpauth://"):
        u = urllib.parse.urlparse(spec)
        if u.netloc.lower() != "totp":
            raise ValueError("only TOTP QR codes are supported")
        q = urllib.parse.parse_qs(u.query)
        secret = q["secret"][0]
        digits = int(q.get("digits", ["6"])[0])
        period = int(q.get("period", ["30"])[0])
        algo = q.get("algorithm", ["SHA1"])[0].upper()
    else:
        secret = spec
    secret = secret.replace(" ", "").upper()
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    digest = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}[algo]
    return key, digits, period, digest


def totp(key, digits, period, digest, step):
    mac = hmac.new(key, struct.pack(">Q", step), digest).digest()
    off = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return str(code).zfill(digits)


def fresh_code(spec):
    """Generate a code, never reusing the time step of the previous login (servers reject replays)."""
    key, digits, period, digest = parse_totp(spec)
    last = None
    try:
        with open(STATE) as f:
            last = int(f.read().strip())
    except (OSError, ValueError):
        pass
    step = int(time.time()) // period
    if step == last:
        wait = period - (time.time() % period) + 1
        log(f"Waiting {wait:.0f}s for a fresh OTP window")
        time.sleep(wait)
        step = int(time.time()) // period
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w") as f:
            f.write(str(step))
    except OSError:
        pass
    return totp(key, digits, period, digest, step)


def post(server, body):
    req = urllib.request.Request(
        f"https://{server}/ssl-vpn/login.esp",
        data=urllib.parse.urlencode(body).encode(),
        headers={"User-Agent": "PAN GlobalProtect", "Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()) as r:
        return r.read().decode("utf-8", "replace")


def js_var(text, pattern):
    m = re.search(pattern + r'\s*=\s*"((?:[^"\\]|\\.)*)"', text)
    return m.group(1) if m else None


def build_cookie(xml_text, computer):
    root = ET.fromstring(xml_text.strip())
    if root.tag != "jnlp":
        raise ValueError("unexpected login response")
    args = [(a.text or "") for a in root.iter("argument")]
    vals = {}
    for idx, name in SAVED_ARGS.items():
        if idx < len(args):
            v = urllib.parse.unquote(args[idx].strip())
            if v and v not in ("(null)", "-1"):
                vals[name] = v
    if "authcookie" not in vals or "user" not in vals:
        raise ValueError("login response missing authcookie/user")
    parts = [f"{k}={urllib.parse.quote(vals[k], safe='-_.~')}" for k in COOKIE_ORDER if k in vals]
    parts.append(f"computer={urllib.parse.quote(computer, safe='-_.~')}")
    return "&".join(parts)


def main():
    if len(sys.argv) != 3:
        log(__doc__)
        return 3
    creds_file, server = sys.argv[1], sys.argv[2]
    try:
        with open(creds_file) as f:
            lines = f.read().splitlines()
        user, password, totp_spec = lines[0], lines[1], lines[2].strip()
        parse_totp(totp_spec)
    except (OSError, IndexError, ValueError, KeyError) as e:
        log(f"Bad credentials file {creds_file}: {type(e).__name__} (need user, password, TOTP secret)")
        return 3

    computer = socket.gethostname()
    base = {
        "jnlpReady": "jnlpReady", "ok": "Login", "direct": "yes", "clientVer": "4100",
        "prot": "https:", "ipv6-support": "yes", "clientos": "Linux", "os-version": "linux-64",
        "server": server, "computer": computer,
    }

    try:
        resp = post(server, {**base, "user": user, "passwd": password})
        for _ in range(3):
            status = js_var(resp, r"var respStatus")
            if status is None:
                break
            msg = js_var(resp, r"var respMsg") or ""
            if status != "Challenge":
                log(f"Login rejected: {msg or status}")
                return 2
            input_str = js_var(resp, r"thisForm\.inputStr\.value")
            log(f"Server challenge: {msg}")
            resp = post(server, {**base, "inputStr": input_str or "", "user": user, "passwd": fresh_code(totp_spec)})
        else:
            log("Too many challenges")
            return 2
        cookie = build_cookie(resp, computer)
    except urllib.error.HTTPError as e:
        log(f"HTTP error {e.code} from gateway")
        return 2 if e.code in (401, 403, 512) else 4
    except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
        log(f"Network error: {e}")
        return 4
    except (ET.ParseError, ValueError) as e:
        log(f"Unexpected login response: {e}")
        return 4

    log("Login OK")
    print(cookie)
    return 0


if __name__ == "__main__":
    sys.exit(main())
