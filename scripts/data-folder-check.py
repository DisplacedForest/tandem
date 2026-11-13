#!/usr/bin/env python3
import os
import sys

ROOT = "apps/vera-mac/Sources/Vera"
TOKEN = "applicationSupportDirectory"
ALLOWED = {
    "AppLocations.swift",
    "AppLocationsSelftest.swift",
}


PERMIT = "scratchPermitForTests"
PERMIT_HOME = "StartupCleanup.swift"


def test_file(name):
    return "Selftest" in name or "SelfTest" in name


def offenders(repo):
    found = []
    base = os.path.join(repo, ROOT)
    for folder, _, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, start=1):
                    location = f"{os.path.relpath(path, repo)}:{number}"
                    if TOKEN in line and name not in ALLOWED:
                        found.append(f"{location} looks up {TOKEN}")
                    if PERMIT in line and name != PERMIT_HOME and not test_file(name):
                        found.append(f"{location} asks for a clean-up permit outside a selftest")
    return found


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = offenders(repo)
    if found:
        print("Per-user data locations go through AppLocations, and only selftests may ask for a clean-up permit. Found:")
        for entry in found:
            print(f"  {entry}")
        return 1
    print("data folder check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
