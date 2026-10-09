import argparse
import json
import re
import zipfile
from pathlib import Path


def package(app_id: str, output: Path) -> None:
    if not re.fullmatch(r"asdk_app_[a-f0-9]{32}", app_id):
        raise ValueError("Use the verified registered App ID from this dot's native connection settings")
    skill_path = "skills/household-inbox-setup/SKILL.md"
    skill = (Path(__file__).with_name("household_plugin") / skill_path).read_text()
    manifest = {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name": "household-inbox",
        "version": "0.1.0",
        "description": "Connect this dot's private local inbox and verify incoming notifications.",
        "extensions": {"com.openai": {
            "apps": "./.app.json",
            "onboardingSkill": "./" + skill_path,
            "interface": {"displayName": "Household inbox", "shortDescription": "A private inbox for your dot"},
        }},
    }
    apps = {"apps": {"household-inbox": {"id": app_id}}}
    with output.open("xb") as target:
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("plugin.json", json.dumps(manifest, indent=2) + "\n")
            archive.writestr(".app.json", json.dumps(apps, indent=2) + "\n")
            archive.writestr(skill_path, skill)


def main() -> None:
    parser = argparse.ArgumentParser(description="Package setup for an already authorized, registered inbox connection")
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app_id, args.output)


if __name__ == "__main__":
    main()
