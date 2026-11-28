from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Mapping


def settings(environment: Mapping[str, str]) -> tuple[str, str | None]:
    root = Path(environment.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    explicit_config = environment.get("VERA_SIGNING_CONFIG")
    config = Path(explicit_config) if explicit_config else root / "vera" / "signing.json"
    values = {}
    if config.exists():
        values = json.loads(config.read_text())
        if not isinstance(values, dict) or set(values) - {"identity", "keychain", "weather_profile"}:
            raise ValueError("Signing configuration accepts identity, keychain and weather_profile")
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


def weather_profile(environment: Mapping[str, str]) -> Path | None:
    root = Path(environment.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    config = Path(environment.get("VERA_SIGNING_CONFIG", str(root / "vera" / "signing.json")))
    values = json.loads(config.read_text()) if config.exists() else {}
    value = environment.get("VERA_WEATHER_PROFILE", values.get("weather_profile"))
    if value is None:
        return None
    if not isinstance(value, str) or not value or not Path(value).is_absolute() or not Path(value).is_file():
        raise ValueError("Weather profile must name an existing absolute file path")
    return Path(value)


def weather_entitlements(profile: Mapping, bundle_id: str, identity: str) -> dict:
    entitlements = profile.get("Entitlements", {})
    teams = profile.get("TeamIdentifier", [])
    expires = profile.get("ExpirationDate")
    certificates = profile.get("DeveloperCertificates", [])
    if identity == "-" or not any(hashlib.sha1(value).hexdigest().upper() == identity for value in certificates if isinstance(value, bytes)):
        raise ValueError("Weather profile does not authorize the selected signing certificate")
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("Weather profile has expired")
    if profile.get("ProvisionsAllDevices") is not True or entitlements.get("com.apple.developer.weatherkit") is not True:
        raise ValueError("Weather needs a Developer ID provisioning profile with WeatherKit enabled")
    if len(teams) != 1 or not isinstance(teams[0], str):
        raise ValueError("Weather profile has no unique team")
    team = teams[0]
    application_id = entitlements.get("com.apple.application-identifier")
    if application_id != f"{team}.{bundle_id}" or entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Weather profile does not match this app")
    return {"com.apple.developer.weatherkit": True, "com.apple.application-identifier": application_id, "com.apple.developer.team-identifier": team}


def sign(app: Path, environment: Mapping[str, str]) -> None:
    identity, keychain = settings(environment)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("An existing app bundle is required")
    profile = weather_profile(environment)
    entitlements = None
    if profile is not None:
        decoded = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(profile)], check=True, capture_output=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        entitlements = weather_entitlements(plistlib.loads(decoded.stdout), info["CFBundleIdentifier"], identity)
        shutil.copyfile(profile, app / "Contents/embedded.provisionprofile")
    command = ["/usr/bin/codesign", "--force", "--deep", "--sign", identity]
    if identity != "-":
        command += ["--timestamp=none"]
        if keychain:
            command += ["--keychain", keychain]
    command += [str(app.resolve())]
    print("==> Ad-hoc codesign" if identity == "-" else "==> Local identity codesign", flush=True)
    subprocess.run(command, check=True)
    if entitlements is not None:
        with tempfile.TemporaryDirectory(prefix="tandem-weather-sign-") as directory:
            path = Path(directory) / "weather.plist"
            path.write_bytes(plistlib.dumps(entitlements))
            outer = [part for part in command[:-1] if part != "--deep"]
            subprocess.run(outer + ["--entitlements", str(path), str(app.resolve())], check=True)
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
