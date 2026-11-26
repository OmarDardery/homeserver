"""Root-only local secret manager. Values enter via stdin, never argv."""
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

STATE = Path("/var/lib/homeserver/secrets")
KEY = STATE / "age.key"
STORE = STATE / "runtime.enc"
GITHUB_TOKEN = STATE / "github.token"
GITHUB_REPO = "https://api.github.com/repos/OmarDardery/homeserver"
GITHUB_API = GITHUB_REPO + "/contents/secrets/runtime.enc"
GITHUB_HISTORY = GITHUB_REPO + "/commits?path=secrets/runtime.enc&sha=main&per_page=15"
GITHUB_MAIN = GITHUB_REPO + "/commits/main"
DEPLOYED = Path("/var/lib/homeserver/deployed-rev")
SHA = re.compile(r"[0-9a-f]{40}")
RUNTIME = Path("/run/homeserver-secrets")
DECRYPTED = Path("/run/secrets/homeserver-runtime")
OLD_ENV = Path("/var/lib/homeserver/aiostreams/aiostreams.env")
OLD_TOKEN = Path("/var/lib/homeserver/cloudflared/token")
RESERVED = {"GITHUB_TOKEN", "HOMESERVER_GITHUB_TOKEN"}
REQUIRED = {"BASE_URL", "SECRET_KEY", "AIOSTREAMS_AUTH", "AIOSTREAMS_AUTH_REQUIRED"}
TOKEN = "CLOUDFLARE_TUNNEL_TOKEN"
NAME = re.compile(r"[A-Z_][A-Z0-9_]{0,127}")
# Deliberately accept only unambiguous, literal dotenv values.
VALUE = re.compile(r"[A-Za-z0-9_:/@.%+=,!?~&*;()\[\]{}-]{1,16384}")


class Invalid(Exception):
    pass


def run(args, data=None, env=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, check=False)
    if result.returncode:
        raise Invalid("Operation failed: " + args[0] + ". Check service status locally.")
    return result.stdout


def atomic(path, content):
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".secret-")
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
        dfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def validate(data):
    if not isinstance(data, dict) or not REQUIRED <= data.keys():
        raise Invalid("Required AIOStreams settings are missing.")
    for name, value in data.items():
        if not isinstance(name, str) or not NAME.fullmatch(name):
            raise Invalid("Invalid variable name.")
        if not isinstance(value, str) or not VALUE.fullmatch(value):
            raise Invalid("Use a nonempty literal value without whitespace, quotes, dollar signs or backslashes.")
    if data["AIOSTREAMS_AUTH_REQUIRED"] != "true":
        raise Invalid("AIOStreams authentication must remain enabled.")
    if not re.fullmatch(r"[^:]+:.+", data["AIOSTREAMS_AUTH"]):
        raise Invalid("AIOSTREAMS_AUTH must be username:password.")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", data["SECRET_KEY"]):
        raise Invalid("SECRET_KEY must be 64 hexadecimal characters.")
    if TOKEN in data and not re.fullmatch(r"[A-Za-z0-9_+/=-]+", data[TOKEN]):
        raise Invalid("Enter only the Cloudflare tunnel token.")
    return data


def decrypt():
    env = dict(os.environ, SOPS_AGE_KEY_FILE=str(KEY))
    return validate(json.loads(run(["sops", "--decrypt", "--input-type", "binary",
                                    "--output-type", "binary", str(STORE)], env=env)))


def encrypt(data):
    validate(data)
    recipient = run(["age-keygen", "-y", str(KEY)]).decode().strip()
    encrypted = run(["sops", "--encrypt", "--age", recipient, "--input-type", "binary",
                     "--output-type", "binary", "/dev/stdin"],
                    json.dumps(data).encode())
    return encrypted


def save(data):
    atomic(STORE, encrypt(data))


def initialize():
    if STORE.exists():
        decrypt()
        return
    if GITHUB_TOKEN.exists():
        raise Invalid("Encrypted cache missing. Restore it from GitHub before booting services.")
    if not KEY.exists():
        atomic(KEY, run(["age-keygen"]))
    data = {"BASE_URL": "https://aio.dardery.work", "SECRET_KEY": secrets.token_hex(32),
            "AIOSTREAMS_AUTH": "admin:" + secrets.token_hex(24),
            "AIOSTREAMS_AUTH_REQUIRED": "true"}
    if OLD_ENV.exists():
        for line in OLD_ENV.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            name, sep, value = line.partition("=")
            if not sep or not NAME.fullmatch(name) or name == TOKEN:
                raise Invalid("Legacy environment needs manual migration.")
            data[name] = value
    if OLD_TOKEN.exists() and OLD_TOKEN.read_text().strip():
        data[TOKEN] = OLD_TOKEN.read_text().strip()
    save(data)
    if decrypt() != data:
        raise Invalid("Encrypted migration could not be verified.")


# Only ciphertext crosses this boundary. Never send the age identity or API token
# as content. Reject redirects and ambient proxies to avoid forwarding credentials.
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def github_api(token, method="GET", payload=None, url=None):
    url = url or GITHUB_API + ("?ref=main" if method == "GET" else "")
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "homeserver-secrets",
    })
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            return json.loads(response.read(2_000_000))
    except urllib.error.HTTPError as exc:
        if exc.code == 404 and method == "GET":
            return None
        if exc.code in (409, 422):
            raise Invalid("GitHub rejected the update. Refresh or pull before retrying.") from None
        raise Invalid("GitHub request failed. Check repository token permissions.") from None
    except (OSError, ValueError):
        raise Invalid("GitHub is unavailable. No local change was applied; refresh to verify remote state.") from None


def token_value():
    return GITHUB_TOKEN.read_text().strip() if GITHUB_TOKEN.exists() else None


def encrypted_document(blob):
    try:
        obj = json.loads(blob)
        if set(obj) != {"data", "sops"} or not obj["data"].startswith("ENC[AES256_GCM,"):
            raise ValueError()
        if not obj["sops"]["age"] or not obj["sops"]["mac"].startswith("ENC["):
            raise ValueError()
    except (ValueError, TypeError, AttributeError, KeyError):
        raise Invalid("Not a supported SOPS-encrypted binary document.") from None
    return blob


def decrypt_blob(blob):
    encrypted_document(blob)
    env = dict(os.environ, SOPS_AGE_KEY_FILE=str(KEY))
    return validate(json.loads(run(["sops", "--decrypt", "--input-type", "binary",
                                    "--output-type", "binary", "/dev/stdin"], blob, env=env)))


def remote_read(token):
    response = github_api(token)
    if response is None:
        return None
    try:
        if response["type"] != "file" or response["encoding"] != "base64":
            raise ValueError()
        sha = response["sha"]
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError()
        blob = base64.b64decode(response["content"].replace("\n", ""), validate=True)
    except (ValueError, TypeError, KeyError):
        raise Invalid("Unexpected GitHub file response.") from None
    return sha, encrypted_document(blob)


def remote_write(token, blob, previous=None, message="Update encrypted homeserver secrets"):
    # Validate ciphertext and its decryptability before uploading it.
    decrypt_blob(blob)
    payload = {"message": message, "branch": "main",
               "content": base64.b64encode(blob).decode("ascii")}
    if previous is not None:
        payload["sha"] = previous[0]
    result = github_api(token, "PUT", payload)
    if not result or not result.get("content", {}).get("sha"):
        raise Invalid("GitHub commit could not be confirmed. Refresh before retrying.")


def sync_status():
    token = token_value()
    if not token:
        return "Local only — connect GitHub to enable encrypted commits."
    try:
        remote = remote_read(token)
        if remote is None:
            return "Remote file missing or inaccessible — reconnect to publish explicitly."
        return ("Synced with GitHub." if remote[1] == STORE.read_bytes()
                else "Remote differs — pull explicitly before editing.")
    except Invalid:
        return "GitHub unavailable — existing local secrets remain active."


def github_connect(token):
    if not isinstance(token, str) or not re.fullmatch(r"github_pat_[A-Za-z0-9_]{20,255}", token):
        raise Invalid("Provide a fine-grained GitHub personal access token.")
    remote = remote_read(token)
    if remote is None:
        remote_write(token, STORE.read_bytes())
    # A different remote is never overwritten; explicit pull requires the age key.
    atomic(GITHUB_TOKEN, (token + "\n").encode())


def change_message(old, data):
    # Variable names only; values never appear in commit messages.
    parts = []
    for label, names in (("set", sorted(k for k in data if old.get(k) != data[k])),
                         ("remove", sorted(set(old) - set(data)))):
        if names:
            parts.append(label + " " + ", ".join(names[:8]) + (" …" if len(names) > 8 else ""))
    return "Secrets: " + ("; ".join(parts) or "update")


def commit_update(data, old=None):
    token = token_value()
    if token is None:
        save(data)
        return
    remote = remote_read(token)
    if remote is None or remote[1] != STORE.read_bytes():
        raise Invalid("Remote secrets differ or are missing. Pull or reconnect before editing.")
    blob = encrypt(data)
    remote_write(token, blob, remote,
                 change_message(old, data) if old is not None else "Update encrypted homeserver secrets")
    # GitHub is authoritative. A crash here is recoverable using Pull from GitHub.
    atomic(STORE, blob)


def pull_remote(old):
    token = token_value()
    if token is None:
        raise Invalid("Connect GitHub first.")
    remote = remote_read(token)
    if remote is None:
        raise Invalid("No accessible encrypted secrets file in GitHub.")
    data = decrypt_blob(remote[1])
    if remote[1] != STORE.read_bytes():
        atomic(STORE, remote[1])
        apply_changes(old, data)


def push_remote():
    # Explicit overwrite of GitHub with this server's ciphertext (UI confirms first).
    token = token_value()
    if token is None:
        raise Invalid("Connect GitHub first.")
    remote = remote_read(token)
    local = STORE.read_bytes()
    if remote is not None and remote[1] == local:
        return "GitHub already has these encrypted secrets."
    remote_write(token, local, remote, "Push encrypted homeserver secrets from server")
    return "Encrypted secrets pushed to GitHub."


def ensure_remote():
    # Used before a server update: publish if missing, never overwrite a different remote.
    token = token_value()
    if token is None:
        return "GitHub not connected; secrets stay local."
    remote = remote_read(token)
    local = STORE.read_bytes()
    if remote is None:
        remote_write(token, local)
        return "Published encrypted secrets to GitHub."
    if remote[1] != local:
        raise Invalid("GitHub secrets differ from this server. Use Pull or Push in Cockpit, then update again.")
    return "Encrypted secrets match GitHub."


def update_status():
    # Compare the deployed commit (written by the installer) with GitHub main.
    token = token_value()
    if token is None:
        return {"state": "unknown", "message": "Connect GitHub to check for updates.", "commits": []}
    deployed = DEPLOYED.read_text().strip() if DEPLOYED.exists() else ""
    latest = (github_api(token, url=GITHUB_MAIN) or {}).get("sha", "")
    if not SHA.fullmatch(latest):
        raise Invalid("Unexpected GitHub response for main.")
    if not SHA.fullmatch(deployed):
        return {"state": "unknown", "message": "Deployed version unknown; update once to record it.",
                "latest": latest[:7], "commits": []}
    if deployed == latest:
        return {"state": "current", "message": "Up to date.", "deployed": deployed[:7],
                "latest": latest[:7], "commits": []}
    compare = github_api(token, url=f"{GITHUB_REPO}/compare/{deployed}...{latest}") or {}
    try:
        behind = int(compare["ahead_by"])
        commits = [{"sha": c["sha"][:7], "message": c["commit"]["message"].splitlines()[0][:200]}
                   for c in compare.get("commits", [])][-10:][::-1]
    except (TypeError, KeyError, ValueError, IndexError, AttributeError):
        raise Invalid("Unexpected GitHub compare response.") from None
    return {"state": "behind", "message": f"{behind} update{'s' if behind != 1 else ''} available.",
            "deployed": deployed[:7], "latest": latest[:7], "commits": commits}


def materialize(data):
    validate(data)
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    atomic(RUNTIME / "aiostreams.env", "".join(
        f"{k}={v}\n" for k, v in sorted(data.items()) if k != TOKEN).encode())
    token = RUNTIME / "token"
    if TOKEN in data:
        atomic(token, (data[TOKEN] + "\n").encode())
    else:
        token.unlink(missing_ok=True)


def refresh():
    # Invoke the same sops-nix manifest directly; restarting the systemd unit
    # would stop dependent services and could deadlock on this helper lock.
    run([os.environ["HOMESERVER_SOPS_INSTALLER"], os.environ["HOMESERVER_SOPS_MANIFEST"]],
        env=dict(os.environ, SOPS_RESTART_UNITS_VIA_SYSTEMCTL="1"))
    materialize(validate(json.loads(DECRYPTED.read_bytes())))


def update(old, data):
    if old == data:
        raise Invalid("Value unchanged. Use Retry apply if the prior restart failed.")
    commit_update(data, old)
    apply_changes(old, data)


def history():
    token = token_value()
    if token is None:
        return []
    commits = github_api(token, url=GITHUB_HISTORY)
    try:
        return [{"sha": c["sha"][:7], "message": c["commit"]["message"].splitlines()[0][:200],
                 "date": c["commit"]["committer"]["date"],
                 "author": (c.get("author") or {}).get("login") or c["commit"]["author"]["name"]}
                for c in (commits or [])]
    except (TypeError, KeyError, AttributeError, IndexError):
        raise Invalid("Unexpected GitHub history response.") from None


def check_name(name):
    if not isinstance(name, str) or not NAME.fullmatch(name) or name in RESERVED:
        raise Invalid("Invalid or reserved variable name.")
    return name


def parse_import(text, data):
    if not isinstance(text, str) or len(text) > 60000:
        raise Invalid("Paste a dotenv document under 60 KB.")
    changed = dict(data)
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, sep, value = line.partition("=")
        name = name.strip()
        if not sep or not NAME.fullmatch(name) or name in RESERVED:
            raise Invalid(f"Line {number}: expected NAME=value with a valid, unreserved name.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        if not VALUE.fullmatch(value):
            raise Invalid(f"Line {number} ({name}): value contains unsupported characters.")
        changed[name] = value
    return validate(changed)


def describe(data):
    return [{"name": n, "configured": n in data, "required": n in REQUIRED,
             "scope": "cloudflared" if n == TOKEN else "aiostreams"}
            for n in sorted(set(data) | {TOKEN})]


def apply_changes(old, data):
    aio_changed = {k:v for k,v in old.items() if k != TOKEN} != {
        k:v for k,v in data.items() if k != TOKEN}
    token_changed = old.get(TOKEN) != data.get(TOKEN)
    try:
        refresh()
        if aio_changed:
            run(["systemctl", "restart", "aiostreams-stack.service"])
        if token_changed:
            run(["systemctl", "restart" if TOKEN in data else "stop", "cloudflared.service"])
    except Invalid:
        # Keep desired state encrypted so Apply can retry; don't silently report success.
        raise Invalid("Saved securely, but applying failed. Check Services and retry Apply.")


def main():
    if os.geteuid() != 0:
        raise Invalid("Administrative access is required.")
    os.umask(0o077)
    # Prevent accidental plaintext core dumps.
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    with (STATE / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == "init":
            initialize()
            return
        if action == "materialize":
            data = validate(json.loads(DECRYPTED.read_bytes()))
            materialize(data)
            # Only remove obsolete plaintext after verifying successful decryption.
            for path in (OLD_ENV, OLD_TOKEN):
                path.unlink(missing_ok=True)
            return
        data = decrypt()
        if action == "github-status":
            print(json.dumps(sync_status()))
        elif action == "github-connect":
            github_connect(json.loads(sys.stdin.read(65536)).get("token"))
        elif action == "github-pull":
            pull_remote(data)
        elif action == "github-push":
            print(json.dumps(push_remote()))
        elif action == "github-ensure":
            print(ensure_remote())
        elif action == "update-status":
            print(json.dumps(update_status()))
        elif action == "list":
            print(json.dumps(describe(data)))
        elif action == "history":
            print(json.dumps(history()))
        elif action == "export":
            # Ciphertext only: the age identity never leaves the host.
            sys.stdout.write(encrypted_document(STORE.read_bytes()).decode())
        elif action == "import":
            update(data, parse_import(json.loads(sys.stdin.read(65536)).get("text"), data))
        elif action in ("set", "delete", "reveal"):
            request = json.loads(sys.stdin.read(65536))
            name = check_name(request.get("name"))
            if action == "reveal":
                print(json.dumps(data.get(name)))
                return
            changed = dict(data)
            if action == "set":
                changed[name] = request.get("value")
            else:
                if name in REQUIRED:
                    raise Invalid("Required variables cannot be deleted.")
                changed.pop(name, None)
            update(data, validate(changed))
        elif action == "apply":
            refresh()
            run(["systemctl", "restart", "aiostreams-stack.service"])
            run(["systemctl", "restart" if TOKEN in data else "stop", "cloudflared.service"])
        else:
            raise Invalid("Unknown action.")


if __name__ == "__main__":
    try:
        main()
    except Invalid as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Secret operation failed. No secret values are logged.", file=sys.stderr)
        sys.exit(1)
