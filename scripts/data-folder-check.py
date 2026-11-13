#!/usr/bin/env python3
import bisect
import os
import re
import sys

ROOT = "apps/vera-mac/Sources/Vera"

GUARDED = r"(?:UserDefaults|URLSession|KeychainNativeCredentialStore|NWConnection|WKWebView)"

RULES = [
    ("support", r"applicationSupportDirectory",
     {"AppLocations.swift", "AppLocationsSelftest.swift"},
     "looks up applicationSupportDirectory"),
    ("home", r"homeDirectoryForCurrentUser|NSHomeDirectory",
     {"AppLocations.swift", "AppLocationsSelftest.swift", "EngineManager.swift", "NativeCompanionLive.swift",
      "NativePiModelBroker.swift", "NativePiPresentation.swift"},
     "looks up the home folder"),
    ("standard", r"\bUserDefaults\s*\.\s*standard\b|\bUserDefaults\s*\??\s*=\s*\.\s*standard\b",
     {"AppLocations.swift"},
     "uses the standard preferences"),
    ("suite", r"\bUserDefaults\s*(?:\.\s*init\s*)?\(\s*suiteName\b|\.\s*init\s*\(\s*suiteName\s*:",
     {"MemoryPreferences.swift"},
     "opens a preferences suite"),
    ("storage", r"@AppStorage\s*\((?![^)]*\bstore\s*:)",
     set(),
     "keeps a preference without naming its store"),
    ("keychain", r"\bKeychainNativeCredentialStore\s*(?:\.\s*init\s*)?\((?![^)]*\boperations\s*:)"
     r"|\bKeychainNativeCredentialStore\s*\??\s*=\s*\.\s*init\s*\((?![^)]*\boperations\s*:)"
     r"|\.\s*init\s*\(\s*allowsInteraction\s*:(?![^)]*\boperations\s*:)",
     {"AppLocations.swift", "NativeProviderSmoke.swift", "OwnSettingsSelftest.swift"},
     "builds the real Keychain store"),
    ("session", r"\bURLSession\s*(?:\.\s*init\s*)?\(|\.\s*init\s*\(\s*configuration\s*:",
     {"OutboundGuard.swift"},
     "builds a URLSession outside the guarded factory"),
    ("connection", r"\bNWConnection\s*(?:\.\s*init\s*)?\(|\.\s*init\s*\(\s*(?:host|to)\s*:[^)]*\busing\s*:",
     {"NativePageTransport.swift"},
     "opens a network connection outside the guarded page reader"),
    ("webview", r"\bWKWebView\s*(?:\.\s*init\s*)?\(|\bWKWebView\s*\??\s*=\s*\.\s*init\s*\(|\.\s*init\s*\(\s*frame\s*:[^)]*\bconfiguration\s*:",
     {"OutboundGuard.swift"},
     "builds a web view outside the guarded factory"),
    ("by-name", r"\b" + GUARDED + r"\s*\.\s*init\b(?!\s*\()",
     set(),
     "passes a guarded initializer around by name"),
    ("alias", r"\btypealias\s+\w+\s*(?:<[^>]*>)?\s*=[^;{}]*?\b" + GUARDED + r"\b",
     set(),
     "renames a guarded type"),
    ("inferred", r"(?:->|:)\s*" + GUARDED + r"\s*[?!]?\s*(?:=|in\b|\{(?:[^{}]|\{[^{}]*\})*?(?:\b(?:get|set|willSet|didSet)\s*\{)?[^{}]*?(?:\breturn\b)?)"
     r"\s*\.\s*(?:standard\b|shared\b|init\b(?!\s*\([^)]*\boperations\s*:))",
     {"AppLocations.swift", "OutboundGuard.swift", "MemoryPreferences.swift"},
     "builds a guarded value from its declared type"),
    ("socket", r"(?<!OutboundGuard)(?<!OutboundGuard )\.\s*webSocketTask\s*\(",
     {"OutboundGuard.swift"},
     "opens a socket outside the guarded factory"),
    ("secitem", r"\bSecItem(?:CopyMatching|Add|Update|Delete)\s*\(",
     {"NativeChatSettings.swift", "NativePiCheckpoint.swift", "SelectedCredentialAuthorization.swift"},
     "calls the Keychain directly"),
]

COMPILED = [(rule, re.compile(pattern), allowed, problem) for rule, pattern, allowed, problem in RULES]

QUALIFIER = re.compile(r"\b(?:Foundation|Network|WebKit|Security|CoreServices|CFNetwork|Darwin)\s*\.\s*(?=" + GUARDED + r"\b|SecItem)")

PERMIT = "scratchPermitForTests"
PERMIT_HOME = "StartupCleanup.swift"

CAUGHT = [
    ("support", "let s = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)"),
    ("home", "let h = FileManager.default.homeDirectoryForCurrentUser"),
    ("home", "let h = NSHomeDirectory()"),
    ("standard", "let d = UserDefaults.standard"),
    ("standard", "let d: UserDefaults = .standard"),
    ("standard", "let d = Foundation.UserDefaults.standard"),
    ("suite", "let d = UserDefaults(suiteName: \"x\")"),
    ("suite", "let d: UserDefaults? = .init(suiteName: \"x\")"),
    ("suite", "let d = UserDefaults.init(suiteName: \"x\")"),
    ("suite", "let d = UserDefaults\n    (suiteName: \"x\")"),
    ("suite", "let d = Foundation.UserDefaults(suiteName: \"x\")"),
    ("storage", "@AppStorage(\"x\") var x = false"),
    ("keychain", "let k = KeychainNativeCredentialStore()"),
    ("keychain", "let k = KeychainNativeCredentialStore(allowsInteraction: false)"),
    ("keychain", "let k: KeychainNativeCredentialStore = .init()"),
    ("keychain", "let k: KeychainNativeCredentialStore = .init(allowsInteraction: false)"),
    ("keychain", "let k = KeychainNativeCredentialStore\n    .init()"),
    ("session", "let s = URLSession(configuration: .ephemeral)"),
    ("session", "let s: URLSession = .init(configuration: .ephemeral)"),
    ("session", "let s: URLSession = .init(configuration: .ephemeral, delegate: nil, delegateQueue: nil)"),
    ("session", "let s = URLSession.init(configuration: .ephemeral)"),
    ("session", "let s = URLSession\n    (\n configuration: .ephemeral)"),
    ("session", "let s = Foundation.URLSession(configuration: .ephemeral)"),
    ("connection", "let c = NWConnection(host: h, port: p, using: .tcp)"),
    ("connection", "let c: NWConnection = .init(host: h, port: p, using: .tcp)"),
    ("connection", "let c = Network.NWConnection(host: h, port: p, using: .tcp)"),
    ("webview", "let w = WKWebView()"),
    ("webview", "let w: WKWebView = .init()"),
    ("webview", "let w: WKWebView = .init(frame: .zero, configuration: c)"),
    ("webview", "let w = WKWebView\n    (frame: .zero, configuration: c)"),
    ("webview", "let w = WebKit.WKWebView()"),
    ("by-name", "let make = URLSession.init"),
    ("by-name", "let make = Foundation.UserDefaults.init"),
    ("alias", "typealias Session = URLSession"),
    ("alias", "typealias Prefs = UserDefaults"),
    ("alias", "typealias Prefs = Foundation.UserDefaults"),
    ("alias", "typealias Web = WebKit.WKWebView"),
    ("alias", "typealias Maybe = Optional<URLSession>"),
    ("inferred", "func prefs() -> UserDefaults { .standard }"),
    ("inferred", "func prefs() -> UserDefaults { return .standard }"),
    ("inferred", "var prefs: UserDefaults { .standard }"),
    ("inferred", "func session() -> URLSession { .init(configuration: .ephemeral) }"),
    ("inferred", "let make = { () -> URLSession in .init(configuration: .ephemeral) }"),
    ("inferred", "var web: WKWebView { .init() }"),
    ("inferred", "func prefs() -> Foundation.UserDefaults? { .init(suiteName: \"x\") }"),
    ("inferred", "var d: UserDefaults { get { return .standard } }"),
    ("inferred", "var d: UserDefaults { get { .standard } set { } }"),
    ("inferred", "var d: UserDefaults { set { } get { return .standard } }"),
    ("inferred", "var d: UserDefaults {\n  get {\n    return .standard\n  }\n}"),
    ("inferred", "func s() -> URLSession { let x = 1; return .shared }"),
    ("inferred", "var s: URLSession = .shared"),
    ("inferred", "var w: WKWebView { get { .init() } }"),
    ("socket", "let t = URLSession.shared.webSocketTask(with: url)"),
    ("socket", "let t = session\n   .webSocketTask(with: url)"),
    ("secitem", "_ = SecItemCopyMatching(q, &r)"),
    ("secitem", "_ = SecItemDelete(q)"),
    ("secitem", "_ = Security.SecItemAdd(q, nil)"),
    ("permit", "let p = StartupCleanup.scratchPermitForTests(inputs, scratchRoot: root)"),
]

CLEAN = [
    "let s = OutboundGuard.session(configuration: c)",
    "let w = OutboundGuard.webView()",
    "let d = AppLocations.preferences",
    "let k = KeychainNativeCredentialStore(allowsInteraction: false, operations: ops)",
    "let k: KeychainNativeCredentialStore = .init(operations: ops)",
    "@AppStorage(\"x\", store: AppLocations.preferences) var x = false",
    "let shared = URLSession.shared",
    "func use(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: \"x\") }",
    "var companionDefaults: UserDefaults = AppLocations.preferences",
    "func make() -> WKWebView { OutboundGuard.webView() }",
    "var session: URLSession = URLSession.shared",
    "let t = try OutboundGuard.webSocketTask(with: url)",
    "var d: UserDefaults { get { AppLocations.preferences } }",
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


def problems(name, text, rules=False):
    flat, starts = collapse(text)
    flat = QUALIFIER.sub(lambda match: " " * len(match.group(0)), flat)
    found = []
    for rule, pattern, allowed, problem in COMPILED:
        if name in allowed:
            continue
        for match in pattern.finditer(flat):
            found.append((original_line(text, starts, match.start()), rule if rules else problem))
    if PERMIT in text and name != PERMIT_HOME and not test_file(name):
        for number, line in enumerate(text.splitlines(), start=1):
            if PERMIT in line:
                found.append((number, "permit" if rules else "asks for a clean-up permit outside a selftest"))
    return sorted(set(found))


def self_check():
    failures = []
    for rule, sample in CAUGHT:
        tripped = {found for _, found in problems("Probe.swift", sample, rules=True)}
        if rule not in tripped:
            failures.append(f"not caught by {rule}: {sample!r}")
    for sample in CLEAN:
        if problems("Probe.swift", sample):
            failures.append(f"wrongly caught: {sample!r}")
    covered = {rule for rule, _ in CAUGHT}
    for rule in [entry[0] for entry in RULES] + ["permit"]:
        if rule not in covered:
            failures.append(f"no example trips the {rule} rule")
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
