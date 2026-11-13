#!/usr/bin/env python3
import bisect
import os
import re
import sys

ROOT = "apps/vera-mac/Sources/Vera"

GUARDED = r"(?:UserDefaults|URLSession|KeychainNativeCredentialStore|NWConnection|WKWebView)"

RULES = [
    (r"applicationSupportDirectory",
     {"AppLocations.swift", "AppLocationsSelftest.swift"},
     "looks up applicationSupportDirectory"),
    (r"homeDirectoryForCurrentUser|NSHomeDirectory",
     {"AppLocations.swift", "AppLocationsSelftest.swift", "EngineManager.swift", "NativeCompanionLive.swift",
      "NativePiModelBroker.swift", "NativePiPresentation.swift"},
     "looks up the home folder"),
    (r"\bUserDefaults\s*\.\s*standard\b|\bUserDefaults\s*=\s*\.\s*standard\b|:\s*UserDefaults\s*\??\s*=\s*\.\s*standard\b",
     {"AppLocations.swift"},
     "uses the standard preferences"),
    (r"\bUserDefaults\s*(?:\.\s*init\s*)?\(\s*suiteName\b|\.\s*init\s*\(\s*suiteName\s*:",
     {"MemoryPreferences.swift"},
     "opens a preferences suite"),
    (r"@AppStorage\s*\((?![^)]*\bstore\s*:)",
     set(),
     "keeps a preference without naming its store"),
    (r"\bKeychainNativeCredentialStore\s*(?:\.\s*init\s*)?\((?![^)]*\boperations\s*:)"
     r"|\bKeychainNativeCredentialStore\s*\??\s*=\s*\.\s*init\s*\((?![^)]*\boperations\s*:)"
     r"|\.\s*init\s*\(\s*allowsInteraction\s*:(?![^)]*\boperations\s*:)",
     {"AppLocations.swift", "NativeProviderSmoke.swift", "OwnSettingsSelftest.swift"},
     "builds the real Keychain store"),
    (r"\bURLSession\s*(?:\.\s*init\s*)?\(|\.\s*init\s*\(\s*configuration\s*:",
     {"OutboundGuard.swift"},
     "builds a URLSession outside the guarded factory"),
    (r"\bNWConnection\s*(?:\.\s*init\s*)?\(|\.\s*init\s*\(\s*(?:host|to)\s*:[^)]*\busing\s*:",
     {"NativePageTransport.swift"},
     "opens a network connection outside the guarded page reader"),
    (r"\bWKWebView\s*(?:\.\s*init\s*)?\(|\bWKWebView\s*\??\s*=\s*\.\s*init\s*\(|\.\s*init\s*\(\s*frame\s*:[^)]*\bconfiguration\s*:",
     {"OutboundGuard.swift"},
     "builds a web view outside the guarded factory"),
    (r"\b" + GUARDED + r"\s*\.\s*init\b(?!\s*\()",
     set(),
     "passes a guarded initializer around by name"),
    (r"\btypealias\s+\w+\s*=\s*" + GUARDED + r"\b",
     set(),
     "renames a guarded type"),
    (r"\bSecItem(?:CopyMatching|Add|Update|Delete)\s*\(",
     {"NativeChatSettings.swift", "NativePiCheckpoint.swift", "SelectedCredentialAuthorization.swift"},
     "calls the Keychain directly"),
]

COMPILED = [(re.compile(pattern), allowed, problem) for pattern, allowed, problem in RULES]

PERMIT = "scratchPermitForTests"
PERMIT_HOME = "StartupCleanup.swift"

CAUGHT = [
    "let d = UserDefaults.standard",
    "let d: UserDefaults = .standard",
    "let d = UserDefaults(suiteName: \"x\")",
    "let d: UserDefaults? = .init(suiteName: \"x\")",
    "let d = UserDefaults.init(suiteName: \"x\")",
    "let d = UserDefaults\n    (suiteName: \"x\")",
    "let s = URLSession(configuration: .ephemeral)",
    "let s: URLSession = .init(configuration: .ephemeral)",
    "let s: URLSession = .init(configuration: .ephemeral, delegate: nil, delegateQueue: nil)",
    "let s = URLSession.init(configuration: .ephemeral)",
    "let s = URLSession\n    (\n configuration: .ephemeral)",
    "let make = URLSession.init",
    "typealias Session = URLSession",
    "typealias Prefs = UserDefaults",
    "let k = KeychainNativeCredentialStore()",
    "let k = KeychainNativeCredentialStore(allowsInteraction: false)",
    "let k: KeychainNativeCredentialStore = .init()",
    "let k: KeychainNativeCredentialStore = .init(allowsInteraction: false)",
    "let k = KeychainNativeCredentialStore\n    .init()",
    "let c = NWConnection(host: h, port: p, using: .tcp)",
    "let c: NWConnection = .init(host: h, port: p, using: .tcp)",
    "let w = WKWebView()",
    "let w: WKWebView = .init()",
    "let w: WKWebView = .init(frame: .zero, configuration: c)",
    "let w = WKWebView\n    (frame: .zero, configuration: c)",
    "typealias Web = WKWebView",
    "_ = SecItemCopyMatching(q, &r)",
    "_ = SecItemDelete(q)",
    "@AppStorage(\"x\") var x = false",
]

CLEAN = [
    "let s = OutboundGuard.session(configuration: c)",
    "let w = OutboundGuard.webView()",
    "let d = AppLocations.preferences",
    "let k = KeychainNativeCredentialStore(allowsInteraction: false, operations: ops)",
    "let k: KeychainNativeCredentialStore = .init(operations: ops)",
    "@AppStorage(\"x\", store: AppLocations.preferences) var x = false",
    "let shared = URLSession.shared",
]


def test_file(name):
    return "Selftest" in name or "SelfTest" in name


def collapse(text):
    pieces = []
    starts = []
    length = 0
    index = 0
    for match in re.finditer(r"\s+", text):
        if match.start() > index:
            starts.append((length, index))
            pieces.append(text[index:match.start()])
            length += match.start() - index
        starts.append((length, match.start()))
        pieces.append(" ")
        length += 1
        index = match.end()
    if index < len(text):
        starts.append((length, index))
        pieces.append(text[index:])
    return "".join(pieces), starts


def original_line(text, starts, position):
    slot = bisect.bisect_right(starts, (position, len(text) + 1)) - 1
    collapsed_start, original_start = starts[max(slot, 0)]
    original = original_start + (position - collapsed_start)
    return text.count("\n", 0, original) + 1


def problems(name, text):
    flat, starts = collapse(text)
    found = []
    for pattern, allowed, problem in COMPILED:
        if name in allowed:
            continue
        for match in pattern.finditer(flat):
            found.append((original_line(text, starts, match.start()), problem))
    if PERMIT in text and name != PERMIT_HOME and not test_file(name):
        for number, line in enumerate(text.splitlines(), start=1):
            if PERMIT in line:
                found.append((number, "asks for a clean-up permit outside a selftest"))
    return sorted(set(found))


def self_check():
    failures = []
    for sample in CAUGHT:
        if not problems("Probe.swift", sample):
            failures.append(f"not caught: {sample!r}")
    for sample in CLEAN:
        if problems("Probe.swift", sample):
            failures.append(f"wrongly caught: {sample!r}")
    return failures


def offenders(repo):
    found = []
    base = os.path.join(repo, ROOT)
    for folder, _, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for number, problem in problems(name, text):
                found.append(f"{os.path.relpath(path, repo)}:{number} {problem}")
    return found


def main():
    failures = self_check()
    if failures:
        print("data folder check: its own examples are not handled correctly:")
        for entry in failures:
            print(f"  {entry}")
        return 1
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = offenders(repo)
    if found:
        print("Per-user locations, settings, keys, preferences, network sessions and web views go through AppLocations and "
              "OutboundGuard, and only selftests may ask for a clean-up permit. Found:")
        for entry in found:
            print(f"  {entry}")
        return 1
    print(f"data folder check: ok ({len(CAUGHT)} evasion examples caught)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
