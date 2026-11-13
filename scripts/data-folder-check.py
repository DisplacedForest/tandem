#!/usr/bin/env python3
import os
import re
import sys

ROOT = "apps/vera-mac/Sources/Vera"

RULES = [
    (re.compile(r"applicationSupportDirectory"),
     {"AppLocations.swift", "AppLocationsSelftest.swift"},
     "looks up applicationSupportDirectory"),
    (re.compile(r"homeDirectoryForCurrentUser|NSHomeDirectory"),
     {"AppLocations.swift", "AppLocationsSelftest.swift", "EngineManager.swift", "NativeCompanionLive.swift",
      "NativePiModelBroker.swift", "NativePiPresentation.swift"},
     "looks up the home folder"),
    (re.compile(r"UserDefaults\s*\.\s*standard|UserDefaults\s*=\s*\.standard"),
     {"AppLocations.swift"},
     "uses the standard preferences"),
    (re.compile(r"UserDefaults\s*\(\s*suiteName"),
     set(),
     "opens a preferences suite"),
    (re.compile(r"@AppStorage\((?![^)]*store:)"),
     set(),
     "keeps a preference without naming its store"),
    (re.compile(r"KeychainNativeCredentialStore\((?![^)]*operations:)"),
     {"AppLocations.swift", "NativeProviderSmoke.swift", "OwnSettingsSelftest.swift"},
     "builds the real Keychain store"),
    (re.compile(r"\bURLSession\s*\("),
     {"OutboundGuard.swift"},
     "builds a URLSession outside the guarded factory"),
    (re.compile(r"\bNWConnection\s*\("),
     {"NativePageTransport.swift"},
     "opens a network connection outside the guarded page reader"),
]

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
                    for pattern, allowed, problem in RULES:
                        if name not in allowed and pattern.search(line):
                            found.append(f"{location} {problem}")
                    if PERMIT in line and name != PERMIT_HOME and not test_file(name):
                        found.append(f"{location} asks for a clean-up permit outside a selftest")
    return found


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = offenders(repo)
    if found:
        print("Per-user locations, settings, keys, preferences and network sessions go through AppLocations and "
              "OutboundGuard, and only selftests may ask for a clean-up permit. Found:")
        for entry in found:
            print(f"  {entry}")
        return 1
    print("data folder check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
