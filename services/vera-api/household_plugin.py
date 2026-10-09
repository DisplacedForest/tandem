import argparse
import json
import re
import zipfile
from pathlib import Path


def package(app_id: str, output: Path, plugin_name: str = "household-inbox", version: str = "0.1.0") -> None:
    if not re.fullmatch(r"asdk_app_[a-f0-9]{32}", app_id):
        raise ValueError("Use the verified registered App ID from this dot's native connection settings")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", plugin_name):
        raise ValueError("Use the existing plugin manifest name, or a lowercase name for a new package")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Use a three-part numeric package version")
    skill_path = "skills/household-inbox-setup/SKILL.md"
    skill = (Path(__file__).with_name("household_plugin") / skill_path).read_text()
    manifest = {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name": plugin_name,
        "version": version,
        "description": "Connect this dot's private local inbox and verify incoming notifications.",
        "extensions": {"com.openai": {
            "apps": "./.app.json",
            "onboardingSkill": "./" + skill_path,
            "interface": {"displayName": "Household inbox", "shortDescription": "A private inbox for your dot"},
        }},
    }
    apps = {"apps": {plugin_name: {"id": app_id}}}
    with output.open("xb") as target:
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("plugin.json", json.dumps(manifest, indent=2) + "\n")
            archive.writestr(".app.json", json.dumps(apps, indent=2) + "\n")
            archive.writestr(skill_path, skill)


def main() -> None:
    parser = argparse.ArgumentParser(description="Package setup for an already authorized, registered inbox connection")
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--plugin-name", default="household-inbox")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app_id, args.output, args.plugin_name, args.version)


if __name__ == "__main__":
    main()
