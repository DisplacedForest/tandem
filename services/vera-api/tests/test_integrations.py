"""Integration registry tests. Standalone — run: pytest tests/test_integrations.py

Covers the contract: env-wins-per-field precedence (and env locking), the
enabled-when-configured default (zero-migration for env-driven deployments),
experimental-feature ack enforcement (400/409), kill-switch env vars,
secret non-echo in the API view, scheduler gate inheritance.
"""
import asyncio
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from routers import env_compat as ec
from routers import integrations as ig  # noqa: E402
from routers import integrations_store as ist  # noqa: E402
from routers import conversation_extract, home, home_model, home_reconcile, knowledge_groom, learn, pulse

_ENV_VARS = ["SAMPLE_SERVICE_BASE", "SAMPLE_SERVICE_KEY", "SAMPLE_SERVICE_URL",
             "SAMPLE_SERVICE_API_KEY", "SAMPLE_A_URL", "SAMPLE_B_URL",
             "HOME_ASSISTANT_URL", "HOME_ASSISTANT_TOKEN", "OVERSEERR_URL",
             "OVERSEERR_API_KEY", "UNRAID_API_URL", "UNRAID_API_KEY", "SEARXNG_URL",
             "VERA_EMBED_URL", "VERA_EMBED_MODEL", "VERA_REMINDERS_URL",
             "HOME_EVENTS_ENABLED", "MEDIA_CURATION_ENABLED", "HOME_STATE"]

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
    for k in _ENV_VARS:
        monkeypatch.delenv(k, raising=False)
    ig._last_test.clear()
    yield


def _put(iid, **kw):
    return asyncio.run(ig.update_integration(iid, ig.IntegrationUpdate(**kw)))


# --- resolution & precedence -------------------------------------------------------------

def test_unconfigured_is_off():
    assert ig.integration("sample_service") is None
    entry = _entry("sample_service")
    assert entry["status"] == "unconfigured" and not entry["enabled"]


def _entry(iid):
    return ig._entry(iid, ist.load())


def test_env_configured_means_enabled(monkeypatch):
    monkeypatch.setenv("SAMPLE_SERVICE_URL", "http://sample.example/")
    monkeypatch.setenv("SAMPLE_SERVICE_API_KEY", "k")
    cfg = ig.integration("sample_service")
    assert cfg == {"url": "http://sample.example", "api_key": "k"}
    assert _entry("sample_service")["status"] == "enabled"


def test_env_beats_store(monkeypatch):
    ist.update("sample_service", fields={"url": "http://from-store", "api_key": "store-key"})
    monkeypatch.setenv("SAMPLE_SERVICE_URL", "http://from-env")
    assert ig.integration("sample_service")["url"] == "http://from-env"
    assert ig.integration("sample_service")["api_key"] == "store-key"


def test_store_configured_works_without_env():
    _put("sample_service", fields={"url": "http://runtime", "api_key": "k"})
    assert ig.integration("sample_service")["url"] == "http://runtime"


def test_embeddings_store_configured_resolves():
    ist.update("embeddings", fields={"url": "http://emb.example/v1/", "model": "m1"})
    assert ig.integration("embeddings") == {"url": "http://emb.example/v1", "model": "m1"}


def test_embeddings_unconfigured_is_none():
    assert ig.integration("embeddings") is None
    assert _entry("embeddings")["status"] == "unconfigured"


def test_embeddings_env_configured_means_enabled(monkeypatch):
    monkeypatch.setenv("VERA_EMBED_URL", "http://llm.example/v1")
    monkeypatch.setenv("VERA_EMBED_MODEL", "qwen3-embedding")
    assert ig.integration("embeddings") == {"url": "http://llm.example/v1",
                                            "model": "qwen3-embedding"}
    assert _entry("embeddings")["status"] == "enabled"


def test_runtime_disable_wins_over_configured(monkeypatch):
    monkeypatch.setenv("SAMPLE_SERVICE_URL", "http://x")
    monkeypatch.setenv("SAMPLE_SERVICE_API_KEY", "k")
    _put("sample_service", enabled=False)
    assert ig.integration("sample_service") is None
    assert _entry("sample_service")["status"] == "configured"
    _put("sample_service", enabled=True)
    assert ig.integration("sample_service") is not None


# --- PUT validation ----------------------------------------------------------------------

def test_put_env_pinned_field_is_409(monkeypatch):
    monkeypatch.setenv("SAMPLE_SERVICE_URL", "http://pinned")
    with pytest.raises(Exception) as e:
        _put("sample_service", fields={"url": "http://other"})
    assert getattr(e.value, "status_code", None) == 409


def test_enable_without_required_fields_is_400():
    with pytest.raises(Exception) as e:
        _put("sample_service", enabled=True)
    assert getattr(e.value, "status_code", None) == 400


def test_unknown_integration_and_field():
    with pytest.raises(Exception) as e:
        _put("nope", enabled=True)
    assert getattr(e.value, "status_code", None) == 404
    with pytest.raises(Exception) as e:
        _put("sample_service", fields={"bogus": "x"})
    assert getattr(e.value, "status_code", None) == 422


# --- experimental features: ack enforcement ----------------------------------------------

def _enable_ha(monkeypatch):
    monkeypatch.setenv("HOME_ASSISTANT_URL", "http://ha")
    monkeypatch.setenv("HOME_ASSISTANT_TOKEN", "t")


def test_feature_requires_parent_enabled():
    with pytest.raises(Exception) as e:
        _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True, ack=True)})
    assert getattr(e.value, "status_code", None) == 409


def test_feature_requires_ack(monkeypatch):
    _enable_ha(monkeypatch)
    with pytest.raises(Exception) as e:
        _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True)})
    assert getattr(e.value, "status_code", None) == 400
    assert not ig.feature_enabled("home_assistant", "home_modeling")


def test_feature_ack_round_trip(monkeypatch):
    _enable_ha(monkeypatch)
    _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True, ack=True)})
    assert ig.feature_enabled("home_assistant", "home_modeling")
    # off and on again without re-ack — consent is persisted
    _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=False)})
    assert not ig.feature_enabled("home_assistant", "home_modeling")
    _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True)})
    assert ig.feature_enabled("home_assistant", "home_modeling")


def test_feature_default_off_even_when_parent_enabled(monkeypatch):
    _enable_ha(monkeypatch)
    assert not ig.feature_enabled("home_assistant", "home_modeling")


def test_kill_switch_forces_feature_off(monkeypatch):
    _enable_ha(monkeypatch)
    _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True, ack=True)})
    monkeypatch.setenv("HOME_EVENTS_ENABLED", "false")
    assert not ig.feature_enabled("home_assistant", "home_modeling")


def test_feature_off_when_parent_disabled_later(monkeypatch):
    _enable_ha(monkeypatch)
    _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True, ack=True)})
    _put("home_assistant", enabled=False)
    assert not ig.feature_enabled("home_assistant", "home_modeling")


# --- API view ----------------------------------------------------------------------------

def test_secrets_never_echoed(monkeypatch):
    monkeypatch.setenv("SAMPLE_SERVICE_API_KEY", "super-secret")
    entry = _entry("sample_service")
    secret = next(f for f in entry["fields"] if f["id"] == "api_key")
    assert secret["set"] is True and "value" not in secret
    assert "super-secret" not in str(entry)


def test_paired_with_active_when_both_enabled(monkeypatch):
    for iid, other in (("sample_a", "sample_b"), ("sample_b", "sample_a")):
        monkeypatch.setitem(ig.REGISTRY, iid, {
            "display_name": iid,
            "fields": [{"id": "url", "env": f"{iid.upper()}_URL", "label": "Base URL", "secret": False}],
            "unlocks": [],
            "paired_with": {"id": other, "label": "combined view"},
        })
    monkeypatch.setenv("SAMPLE_A_URL", "http://a")
    assert _entry("sample_a")["paired_with"]["active"] is False
    monkeypatch.setenv("SAMPLE_B_URL", "http://b")
    assert _entry("sample_a")["paired_with"]["active"] is True


# --- scheduler gate inheritance -----------------------------------------------------------

def test_scheduler_jobs_inherit_feature_gates(monkeypatch):
    from routers import scheduler as sch
    j = sch._effective("home_model", None)
    assert j["enabled"] is False and j["gated"]
    _enable_ha(monkeypatch)
    _put("home_assistant", features={"home_modeling": ig.FeatureUpdate(enabled=True, ack=True)})
    j = sch._effective("home_model", None)
    assert j["enabled"] is True and j["gated"] is None
    for ungated in ("pulse", "conversation_extract"):  # weather is vein-gated now
        assert sch._effective(ungated, None)["gated"] is None


def test_scheduler_manual_run_refused_when_gated(vein_shapes):
    from routers import scheduler as sch
    with pytest.raises(Exception) as e:
        asyncio.run(sch.run_job("vein_media"))
    assert getattr(e.value, "status_code", None) == 409


# --- apple_reminders -----------------------------------------------------------------------

def test_apple_reminders_unconfigured_off():
    assert ig.integration("apple_reminders") is None
    assert _entry("apple_reminders")["status"] == "unconfigured"


def test_apple_reminders_env_enabled(monkeypatch):
    monkeypatch.setenv("VERA_REMINDERS_URL", "http://bridge.example/")
    assert ig.integration("apple_reminders") == {"url": "http://bridge.example"}
