"""Root-only local secret manager. Values enter via stdin, never argv."""
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

STATE = Path("/var/lib/homeserver/secrets")
KEY = STATE / "age.key"
STORE = STATE / "runtime.enc"
RUNTIME = Path("/run/homeserver-secrets")
DECRYPTED = Path("/run/secrets/homeserver-runtime")
OLD_ENV = Path("/var/lib/homeserver/aiostreams/aiostreams.env")
OLD_TOKEN = Path("/var/lib/homeserver/cloudflared/token")
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


def save(data):
    validate(data)
    recipient = run(["age-keygen", "-y", str(KEY)]).decode().strip()
    encrypted = run(["sops", "--encrypt", "--age", recipient, "--input-type", "binary",
                     "--output-type", "binary", "/dev/stdin"],
                    json.dumps(data).encode())
    atomic(STORE, encrypted)


def initialize():
    if STORE.exists():
        decrypt()
        return
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
    save(data)
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
        if action == "list":
            print(json.dumps(sorted(set(data) | {TOKEN})))
        elif action in ("set", "delete", "reveal"):
            request = json.loads(sys.stdin.read(65536))
            name = request.get("name")
            if not isinstance(name, str) or not NAME.fullmatch(name):
                raise Invalid("Invalid variable name.")
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
