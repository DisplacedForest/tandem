#!/usr/bin/env python3
import os
import sys

ROOT = "apps/vera-mac/Sources/Vera"
TOKEN = "applicationSupportDirectory"
ALLOWED = {
    "AppLocations.swift",
    "AppLocationsSelftest.swift",
}


def offenders(repo):
    found = []
    base = os.path.join(repo, ROOT)
    for folder, _, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".swift") or name in ALLOWED:
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, start=1):
                    if TOKEN in line:
                        found.append(f"{os.path.relpath(path, repo)}:{number}")
    return found


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = offenders(repo)
    if found:
        print(f"Per-user data locations must be resolved through AppLocations. Found {TOKEN} in:")
        for entry in found:
            print(f"  {entry}")
        return 1
    print("data folder check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
