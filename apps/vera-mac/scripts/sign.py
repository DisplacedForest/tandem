from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Mapping


def settings(environment: Mapping[str, str]) -> tuple[str, str | None]:
    root = Path(environment.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    explicit_config = environment.get("VERA_SIGNING_CONFIG")
    config = Path(explicit_config) if explicit_config else root / "vera" / "signing.json"
    values = {}
    if config.exists():
        values = json.loads(config.read_text())
        if not isinstance(values, dict) or set(values) - {"identity", "keychain"}:
            raise ValueError("Signing configuration must contain only identity and optional keychain")
        if not isinstance(values.get("identity"), str):
            raise ValueError("Signing configuration requires an identity string")
        if "keychain" in values and not isinstance(values["keychain"], str):
            raise ValueError("Signing keychain must be an absolute path string")
    elif explicit_config:
        raise ValueError("The requested signing configuration does not exist")
    identity = environment.get("VERA_SIGNING_IDENTITY", values.get("identity", "-"))
    keychain = environment.get("VERA_SIGNING_KEYCHAIN", values.get("keychain"))
    if identity != "-" and not re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
        raise ValueError("Signing identity must be an exact 40-character certificate fingerprint or -")
    if keychain is not None and (not keychain or not Path(keychain).is_absolute() or not Path(keychain).is_file()):
        raise ValueError("Signing keychain must name an existing absolute file path")
    return identity.upper(), keychain


def sign(app: Path, environment: Mapping[str, str]) -> None:
    identity, keychain = settings(environment)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("An existing app bundle is required")
    command = ["/usr/bin/codesign", "--force", "--deep", "--sign", identity]
    if identity != "-":
        command += ["--timestamp=none"]
        if keychain:
            command += ["--keychain", keychain]
    command += [str(app.resolve())]
    print("==> Ad-hoc codesign" if identity == "-" else "==> Local identity codesign", flush=True)
    subprocess.run(command, check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app.resolve())], check=True)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 sign.py PATH_TO_APP", file=sys.stderr)
        return 2
    try:
        sign(Path(sys.argv[1]), os.environ)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
