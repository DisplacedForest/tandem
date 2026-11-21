import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
MAC_APP_SOURCES = os.path.join(REPO_ROOT, "apps", "vera-mac", "Sources")

LISTENER_TERMS = ("NWListener", "CFSocketCreate", "GCDAsyncSocket", "HTTPServer")

LISTENER_ALLOWLIST = {
    "apps/vera-mac/Sources/Vera/NativePiPresentationSelftest.swift": ("NWListener",),
    "apps/vera-mac/Sources/Vera/OwnSettingsSelftest.swift": ("NWListener",),
}


def _mac_app_sources():
    for root, dirs, files in os.walk(MAC_APP_SOURCES, followlinks=False):
        dirs[:] = [d for d in dirs if d not in (".build", "__pycache__")]
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(root, name)


def _relative(path):
    return os.path.relpath(path, REPO_ROOT).replace(os.sep, "/")


def test_mac_app_opens_no_network_listener():
    offenders = []
    for path in _mac_app_sources():
        rel = _relative(path)
        text = open(path, encoding="utf-8").read()
        for term in LISTENER_TERMS:
            if term in text and term not in LISTENER_ALLOWLIST.get(rel, ()):
                offenders.append(f"{rel}: {term}")
    assert offenders == []


def test_listener_guard_covers_the_mac_app():
    covered = {_relative(p) for p in _mac_app_sources()}
    assert "apps/vera-mac/Sources/Vera/RemindersBridge.swift" in covered
    assert "apps/vera-mac/Sources/Vera/VeraApp.swift" in covered
    for rel in LISTENER_ALLOWLIST:
        assert rel in covered
