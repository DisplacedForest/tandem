import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
API_ROOT = os.path.join(REPO_ROOT, "services", "vera-api")
SCRIPTS_ROOT = os.path.join(REPO_ROOT, "scripts")

CHAT_BACKEND_ENV = ("OWUI_BASE", "OWUI_KEY")

MIGRATION_TOOL = "scripts/migrate_owui_knowledge.py"

THIRD_PARTY_API_V1 = {
    "scripts/migrate_owui_knowledge.py",
    "services/vera-api/routers/overseerr.py",
    "services/vera-api/routers/integrations_probes.py",
    "services/vera-api/routers/scout.py",
}


def _sources():
    for root, dirs, files in os.walk(API_ROOT):
        dirs[:] = [d for d in dirs if d not in ("tests", "__pycache__")]
        for name in files:
            if name.endswith(".py"):
                yield os.path.join(root, name)
    for root, dirs, files in os.walk(SCRIPTS_ROOT):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in files:
            if name.endswith(".py") or name.endswith(".sh"):
                yield os.path.join(root, name)


def _relative(path):
    return os.path.relpath(path, REPO_ROOT).replace(os.sep, "/")


MAC_APP_ROOT = os.path.join(REPO_ROOT, "apps", "vera-mac")

MAC_APP_FORBIDDEN_TERMS = (
    "owui",
    "open webui",
    "open-webui",
    "openwebui",
    "socket.io",
    "socketio",
    "starscream",
)

MAC_APP_RETIRED_KEYS = {
    "apps/vera-mac/Sources/Vera/ConfigStore.swift": ("owui_email", "owui_password"),
    "apps/vera-mac/Sources/Vera/SelfTest.swift": ("owui_email", "owui_password"),
}


def _mac_app_files():
    for root, dirs, files in os.walk(os.path.join(MAC_APP_ROOT, "Sources")):
        dirs[:] = [d for d in dirs if d not in (".build", "__pycache__")]
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(root, name)
    yield os.path.join(MAC_APP_ROOT, "Package.swift")
    yield os.path.join(MAC_APP_ROOT, "Package.resolved")
    scripts = os.path.join(MAC_APP_ROOT, "scripts")
    for name in sorted(os.listdir(scripts)):
        if name.endswith(".sh"):
            yield os.path.join(scripts, name)


def test_sources_read_no_chat_backend_env():
    offenders = []
    for path in _sources():
        rel = _relative(path)
        if rel == MIGRATION_TOOL:
            continue
        source = open(path, encoding="utf-8").read()
        for name in CHAT_BACKEND_ENV:
            if name in source:
                offenders.append(f"{rel}: {name}")
    assert offenders == []


def test_sources_call_no_chat_backend_api_paths():
    offenders = [rel for rel in (_relative(p) for p in _sources())
                 if rel not in THIRD_PARTY_API_V1
                 and "/api/v1/" in open(os.path.join(REPO_ROOT, rel), encoding="utf-8").read()]
    assert offenders == []


def test_guard_covers_the_engine_and_the_scripts():
    covered = {_relative(p) for p in _sources()}
    assert "services/vera-api/routers/health.py" in covered
    assert "services/vera-api/main.py" in covered
    assert "scripts/rag-sync.py" in covered
    assert "scripts/vera-backup.sh" in covered
    assert MIGRATION_TOOL in covered


def test_mac_app_mentions_no_retired_chat_backend():
    offenders = []
    for path in _mac_app_files():
        rel = _relative(path)
        text = open(path, encoding="utf-8").read().lower()
        for literal in MAC_APP_RETIRED_KEYS.get(rel, ()):
            text = text.replace(literal, "")
        for term in MAC_APP_FORBIDDEN_TERMS:
            if term in text:
                offenders.append(f"{rel}: {term}")
    assert offenders == []


def test_guard_covers_the_mac_app():
    covered = {_relative(p) for p in _mac_app_files()}
    assert "apps/vera-mac/Package.swift" in covered
    assert "apps/vera-mac/Package.resolved" in covered
    assert "apps/vera-mac/Sources/Vera/ConfigStore.swift" in covered
    assert "apps/vera-mac/Sources/Vera/VeraApp.swift" in covered
    assert "apps/vera-mac/scripts/package.sh" in covered
