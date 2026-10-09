import argparse
import json
import os
import secrets
from pathlib import Path

from routers.household_auth import EndpointKeys
from routers.household_store import Store


def main() -> None:
    parser = argparse.ArgumentParser(description="Offline administration for local household inbox endpoints")
    parser.add_argument("--database", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    revoke = commands.add_parser("revoke")
    revoke.add_argument("--endpoint", required=True)
    for name in ("provision", "rotate"):
        command = commands.add_parser(name)
        command.add_argument("--endpoint", required=True)
        command.add_argument("--key-output", required=True)
        command.add_argument("--lifetime-seconds", type=int, default=2592000)
        command.add_argument("--consent-confirmed", action="store_true", required=True)
    args = parser.parse_args()
    database = Path(args.database)
    if not database.is_absolute():
        parser.error("Database path must be absolute")
    os.umask(0o077)
    keys = EndpointKeys(Store(str(database)))
    if args.command == "list":
        print(json.dumps(keys.list()))
        return
    if args.command == "revoke":
        keys.revoke(args.endpoint)
        print("Endpoint revoked; pending delivery stopped")
        return
    output = Path(args.key_output)
    if not output.is_absolute() or not output.parent.is_dir():
        parser.error("Key output must be a new absolute file in an existing private directory")
    if output.parent.stat().st_mode & 0o077:
        parser.error("Key output directory must be private (mode 0700)")
    key = secrets.token_urlsafe(32)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(key + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        if args.command == "provision":
            keys.provision(args.endpoint, key, args.lifetime_seconds)
        else:
            keys.rotate(args.endpoint, key, args.lifetime_seconds)
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    print("Endpoint key saved to the requested private file; never paste it into chat")


if __name__ == "__main__":
    main()
