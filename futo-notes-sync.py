#!/usr/bin/env python3
"""
Futo Notes sync + decrypt helper for the Omarchy plugin.

Reads a JSON request from stdin:
    {"serverUrl": "https://notes.example.com", "password": "..."}

Writes a JSON response to stdout:
    {"ok": true, "notes": [ {id, path, title, content, isImage, updatedAt} ]}
    {"ok": false, "error": "..."}

Uses the Futo Notes E2EE format documented at
https://notes.futo.tech/docs/encryption/
"""

import hashlib
import json
import subprocess
import sys
import urllib.error
import urllib.request

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print(json.dumps({
        "ok": False,
        "error": "Python 'cryptography' package is required. Install with: "
                 "sudo pacman -S python-cryptography"
    }))
    sys.exit(0)


# --------------------------------------------------------------------------
# Keyring (libsecret via secret-tool)
# --------------------------------------------------------------------------

KEYRING_SERVICE = "futo-notes"


def keyring_store(server_url, password):
    try:
        subprocess.run(
            ["secret-tool", "store", "--label", "Futo Notes sync password",
             "service", KEYRING_SERVICE, "account", server_url],
            input=password, text=True, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        return False


def keyring_lookup(server_url):
    try:
        r = subprocess.run(
            ["secret-tool", "lookup", "service", KEYRING_SERVICE, "account", server_url],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            return r.stdout.rstrip("\n")
    except Exception:
        pass
    return ""


# --------------------------------------------------------------------------
# HTTP helpers
# --------------------------------------------------------------------------

class HttpError(Exception):
    pass


def request(method, url, token=None, body=None, raw=False, timeout=20):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        if isinstance(body, (bytes, bytearray)):
            data = body
            headers["Content-Type"] = "application/octet-stream"
        else:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read()
            if raw:
                return payload
            if not payload:
                return {}
            return json.loads(payload.decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        raise HttpError("HTTP %s: %s" % (e.code, detail or e.reason))
    except urllib.error.URLError as e:
        raise HttpError("connection failed: %s" % (e.reason,))


# --------------------------------------------------------------------------
# Crypto
# --------------------------------------------------------------------------

def derive_password_key(password, salt, iterations):
    return hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, int(iterations), dklen=32
    )


def unwrap_vault_key(key_material, password):
    salt = bytes.fromhex(key_material["key_salt"])
    kdf = key_material.get("key_kdf") or {}
    iterations = int(kdf.get("iterations", 100000))
    wrapped = bytes.fromhex(key_material["encrypted_vault_key"])

    password_key = derive_password_key(password, salt, iterations)

    # wrapped = [12-byte nonce][ciphertext][16-byte tag]
    nonce = wrapped[:12]
    ciphertext_and_tag = wrapped[12:]
    return AESGCM(password_key).decrypt(nonce, ciphertext_and_tag, None)


def decrypt_blob(vault_key, blob):
    # blob = [12-byte nonce][ciphertext][16-byte tag]
    nonce = blob[:12]
    ciphertext_and_tag = blob[12:]
    return AESGCM(vault_key).decrypt(nonce, ciphertext_and_tag, None)


def parse_frame(plaintext):
    if len(plaintext) < 5:
        raise ValueError("frame too small")
    version = plaintext[0]
    if version != 0x02:
        raise ValueError("unsupported frame version 0x%02x" % version)
    path_len = int.from_bytes(plaintext[1:5], "big")
    if len(plaintext) < 5 + path_len:
        raise ValueError("frame path length out of range")
    path = plaintext[5:5 + path_len].decode("utf-8", "replace")
    content = plaintext[5 + path_len:]
    return path, content


IMAGE_EXTS = ("jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "ico", "avif", "heic")


def title_from_path(path):
    name = path.rsplit("/", 1)[-1]
    if "." in name:
        name = name.rsplit(".", 1)[0]
    return name or "Untitled"


# --------------------------------------------------------------------------
# Blob batch parsing
# --------------------------------------------------------------------------

def parse_blob_batch(data, keys):
    blobs = {}
    offset = 0
    decoder = "utf-8"
    total = len(data)
    for _ in range(len(keys)):
        if offset + 2 > total:
            break
        key_len = (data[offset] << 8) | data[offset + 1]
        offset += 2
        if offset + key_len > total:
            break
        key = data[offset:offset + key_len].decode(decoder, "replace")
        offset += key_len
        if offset >= total:
            break
        status = data[offset]
        offset += 1
        if offset + 4 > total:
            break
        blob_len = int.from_bytes(data[offset:offset + 4], "big")
        offset += 4
        if status == 0 and offset + blob_len <= total:
            blobs[key] = data[offset:offset + blob_len]
        offset += blob_len
    return blobs


# --------------------------------------------------------------------------
# Sync
# --------------------------------------------------------------------------

def sync(server_url, password):
    base = server_url.rstrip("/")

    # 1. Learn auth mode (also validates the URL).
    try:
        root = request("GET", base + "/")
    except HttpError as e:
        return {"ok": False, "error": "Cannot reach server: %s" % e}
    if root.get("name") != "futo-notes":
        return {"ok": False, "error": "That URL does not look like a Futo Notes server."}

    # 2. Sign in.
    try:
        login = request("POST", base + "/api/auth/password/login",
                        body={"password": password})
    except HttpError as e:
        return {"ok": False, "error": "Login failed: %s" % e}
    token = login.get("token")
    if not token:
        return {"ok": False, "error": "Login returned no token."}

    # 3. Pick the vault (oldest collection).
    try:
        coll = request("POST", base + "/api/collections", token=token, body={})
    except HttpError as e:
        return {"ok": False, "error": "Could not open vault: %s" % e}
    collection = coll.get("collection") or {}
    collection_id = collection.get("id")
    if not collection_id:
        return {"ok": False, "error": "Server returned no collection."}

    # 4. Read + unwrap the vault key.
    try:
        key_resp = request("GET", base + "/api/collections/%s/key" % collection_id,
                           token=token)
    except HttpError as e:
        return {"ok": False, "error": "Could not read vault key: %s" % e}
    key_material = key_resp.get("key")
    if not key_material:
        return {"ok": False, "error":
                "This vault has no key yet. Connect the Futo Notes app on a "
                "device first so it creates the vault key."}

    try:
        vault_key = unwrap_vault_key(key_material, password)
    except Exception:
        return {"ok": False, "error": "Wrong sync password (could not decrypt the vault key)."}

    # 5. Pull every object.
    try:
        objects_resp = request(
            "GET",
            base + "/api/collections/%s/objects?sinceVersion=0" % collection_id,
            token=token,
        )
    except HttpError as e:
        return {"ok": False, "error": "Could not list notes: %s" % e}
    objects = objects_resp.get("objects") or []

    live = [o for o in objects if not o.get("deleted") and o.get("blob_key")]
    keys = [o["blob_key"] for o in live]

    # 6. Download blobs (batched, 200 at a time).
    blobs = {}
    for i in range(0, len(keys), 200):
        chunk = keys[i:i + 200]
        try:
            raw = request("POST", base + "/api/blobs/batch", token=token,
                          body={"keys": chunk}, raw=True)
            blobs.update(parse_blob_batch(raw, chunk))
        except HttpError as e:
            return {"ok": False, "error": "Could not download notes: %s" % e}

    # 7. Decrypt each blob into a note.
    notes = []
    for obj in live:
        blob = blobs.get(obj["blob_key"])
        if not blob:
            continue
        try:
            plaintext = decrypt_blob(vault_key, blob)
            path, content = parse_frame(plaintext)
        except Exception as e:
            notes.append({
                "id": obj.get("id"),
                "path": "",
                "title": "[Could not decrypt]",
                "content": str(e),
                "isImage": False,
                "updatedAt": obj.get("updated_at"),
            })
            continue

        ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
        is_image = ext in IMAGE_EXTS
        if is_image:
            body = ""  # base64 image data; not shown as text
        else:
            body = content.decode("utf-8", "replace")

        notes.append({
            "id": obj.get("id"),
            "path": path,
            "title": title_from_path(path),
            "content": body,
            "isImage": is_image,
            "updatedAt": obj.get("updated_at"),
        })

    notes.sort(key=lambda n: (n.get("updatedAt") or ""), reverse=True)
    return {"ok": True, "notes": notes}


def main():
    # Read a single line: QML's Process has no way to close stdin, so we must
    # not wait for EOF. The caller writes one JSON object followed by "\n".
    try:
        line = sys.stdin.readline()
        payload = json.loads(line or "{}")
    except Exception as e:
        print(json.dumps({"ok": False, "error": "bad request: %s" % e}))
        return

    server_url = (payload.get("serverUrl") or "").strip().rstrip("/")
    password = payload.get("password") or ""
    save_password = payload.get("savePassword") is True

    if not server_url:
        print(json.dumps({"ok": False, "error": "No server URL configured."}))
        return

    # Store a freshly entered password in the keyring.
    if save_password and password:
        if not keyring_store(server_url, password):
            print(json.dumps({
                "ok": False,
                "error": "Could not save the password to the keyring (secret-tool)."
            }))
            return

    # Fall back to the keyring when no password was sent (normal refresh).
    if not password:
        password = keyring_lookup(server_url)

    if not password:
        print(json.dumps({
            "ok": False,
            "error": "No password saved. Open settings and enter your sync password."
        }))
        return

    try:
        result = sync(server_url, password)
    except Exception as e:
        result = {"ok": False, "error": "unexpected error: %s" % e}

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()