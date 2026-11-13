#!/usr/bin/env python3
"""Tiny App Store Connect API client (stdlib + openssl): asc.py GET|POST|PATCH <path> [json-body].

The API key comes from the environment (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH) or, for any of
those not set, from ~/.config/clamshell/asc.env (plain NAME=value lines, kept outside the repo).
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

ENV_FILE = os.path.expanduser("~/.config/clamshell/asc.env")


def _env_file():
    values = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    name, value = line.split("=", 1)
                    values[name.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return values


def setting(name, required=True):
    """A value from the environment, else from the private env file."""
    value = os.environ.get(name) or _env_file().get(name)
    if not value and required:
        sys.exit(f"{name} is not set. Export it, or add {name}=... to {ENV_FILE}.")
    return value


def _key():
    return setting("ASC_KEY_ID"), setting("ASC_ISSUER_ID"), os.path.expanduser(setting("ASC_KEY_PATH"))


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der):
    # DER ECDSA signature -> 64-byte r||s for JOSE.
    i = 2 + (1 if der[1] & 0x80 else 0)
    out = b""
    for _ in range(2):
        n = der[i + 1]
        v = der[i + 2 : i + 2 + n].lstrip(b"\0")
        out += v.rjust(32, b"\0")
        i += 2 + n
    return out


def token():
    key_id, issuer, key = _key()
    now = int(time.time())
    head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    msg = f"{head}.{body}".encode()
    if not os.path.isfile(key):
        sys.exit("ASC_KEY_PATH does not point to a readable .p8 file.")
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=msg, capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64(der_to_raw(der))}"


def call(method, path, body=None):
    url = path if path.startswith("http") else f"https://api.appstoreconnect.apple.com/v1/{path}"
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{e.code} {e.read().decode()[:800]}")


if __name__ == "__main__":
    out = call(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
    print(json.dumps(out, indent=1))
