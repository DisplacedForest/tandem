"""Env naming migration tests — canonical names win, deprecated aliases still work for
one release, and a production .env written entirely in old names keeps resolving through
the integration registry. Run: python3 -m pytest tests/test_env_compat.py
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from routers import env_compat as ec  # noqa: E402
from routers import integrations as ig  # noqa: E402
from routers import integrations_store as ist  # noqa: E402

_ALL = [n for pair in ec.ALIASES.items() for n in pair]

SAMPLE_SERVICE = {
    "display_name": "Sample Service",
    "fields": [
        {"id": "url", "env": "SAMPLE_SERVICE_BASE", "label": "Base URL", "secret": False},
        {"id": "api_key", "env": "SAMPLE_SERVICE_KEY", "label": "API key", "secret": True},
    ],
    "unlocks": ["sample lookups"],
}
SAMPLE_ALIASES = {"SAMPLE_SERVICE_BASE": "SAMPLE_SERVICE_URL", "SAMPLE_SERVICE_KEY": "SAMPLE_SERVICE_API_KEY"}


@pytest.fixture(autouse=True)
def _clean(monkeypatch, tmp_path):
    monkeypatch.setattr(ist, "PATH", str(tmp_path / "integrations.json"))
    monkeypatch.setitem(ig.REGISTRY, "sample_service", SAMPLE_SERVICE)
    for new, old in SAMPLE_ALIASES.items():
        monkeypatch.setitem(ec.ALIASES, new, old)
    for n in _ALL + [n for pair in SAMPLE_ALIASES.items() for n in pair]:
        monkeypatch.delenv(n, raising=False)
    yield


def test_canonical_name_wins(monkeypatch):
    monkeypatch.setenv("SEARXNG_BASE", "http://new")
    monkeypatch.setenv("SEARXNG_URL", "http://old")
    assert ec.read("SEARXNG_BASE") == "http://new"


def test_deprecated_name_falls_back(monkeypatch):
    monkeypatch.setenv("SEARXNG_URL", "http://old")
    assert ec.read("SEARXNG_BASE") == "http://old"
    assert ec.read("SEARXNG_BASE", "dflt") == "http://old"
    assert ec.read("SAMPLE_SERVICE_BASE", "dflt") == "dflt"


def test_deprecated_in_use_flags_only_unmigrated(monkeypatch):
    monkeypatch.setenv("SAMPLE_SERVICE_API_KEY", "k")        # old only -> flagged
    monkeypatch.setenv("SAMPLE_SERVICE_BASE", "http://s")    # new only -> not flagged
    monkeypatch.setenv("OVERSEERR_BASE", "http://o")         # both set -> migrated, not flagged
    monkeypatch.setenv("OVERSEERR_URL", "http://o-old")
    flagged = dict(ec.deprecated_in_use())
    assert flagged.get("SAMPLE_SERVICE_API_KEY") == "SAMPLE_SERVICE_KEY"
    assert "SAMPLE_SERVICE_BASE" not in flagged and "OVERSEERR_URL" not in flagged


def test_production_env_in_old_names_still_wires_integrations(monkeypatch):
    """The zero-break guarantee: a .env written entirely pre-convention resolves."""
    monkeypatch.setenv("SAMPLE_SERVICE_URL", "http://sample.example/")
    monkeypatch.setenv("SAMPLE_SERVICE_API_KEY", "old-key")
    monkeypatch.setenv("HOME_ASSISTANT_URL", "http://ha.example")
    monkeypatch.setenv("HOME_ASSISTANT_TOKEN", "old-token")
    assert ig.integration("sample_service") == {"url": "http://sample.example", "api_key": "old-key"}
    ha = ig.integration("home_assistant")
    assert ha == {"url": "http://ha.example", "token": "old-token"}
    # old-name envs still pin their fields against runtime edits
    entry = ig._entry("sample_service", ist.load())
    assert all(f["env_locked"] for f in entry["fields"])
