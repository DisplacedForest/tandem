import asyncio

import pytest

from routers import action_registry
from routers import action_spec as spec
from routers import action_store as astore
from routers import actions

AUTO_VERB = "sample.import_link"
GATED_VERB = "sample.adjust_count"


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _needs_url(args):
    return None if args.get("url") else f"{AUTO_VERB} needs url"


def _needs_count(args):
    return None if "count" in args else f"{GATED_VERB} needs count"


@pytest.fixture(autouse=True)
def harness(tmp_path, monkeypatch):
    monkeypatch.setattr(astore, "DB_PATH", str(tmp_path / "actions.db"))
    calls = []

    async def fake_import(args):
        calls.append(args)
        return {"ok": True, "slug": "page", "name": "Page",
                "url": "http://links.test/r/page"}

    async def fake_adjust(args):
        calls.append(args)
        return {"ok": True}

    action_registry.register_action(
        AUTO_VERB, validate=_needs_url, preview=lambda a: f"Import {a.get('url')}",
        risk="low", reversible=True, autonomous=True, order=2_000_010, executor=fake_import)
    action_registry.register_action(
        GATED_VERB, validate=_needs_count, preview=lambda a: f"Adjust by {a.get('count')}",
        risk="low", reversible=True, autonomous=False, order=2_000_020, executor=fake_adjust)
    yield calls
    action_registry.unregister_action(AUTO_VERB)
    action_registry.unregister_action(GATED_VERB)


def test_rejects_unenrolled_verbs(harness):
    for verb, args in (("ha.service", {"domain": "light", "service": "turn_on"}),
                       ("knowledge.set", {"type": "appliance", "name": "x"}),
                       (GATED_VERB, {"count": 1}),
                       ("nonexistent.verb", {})):
        r = run(actions.auto(actions.Auto(verb=verb, args=args)))
        assert r["ok"] is False and r.get("rejected") is True
    assert harness == []                       # no executor ever ran
    assert astore.recent_log() == []           # nothing audited


def test_validates_args():
    r = run(actions.auto(actions.Auto(verb=AUTO_VERB, args={})))
    assert r["ok"] is False and "url" in r["error"]


def test_executes_and_audits(harness):
    r = run(actions.auto(actions.Auto(
        verb=AUTO_VERB, args={"url": "https://x.test/r/page"})))
    assert r["ok"] is True
    assert r["result"]["slug"] == "page"
    assert harness == [{"url": "https://x.test/r/page"}]
    row = astore.recent_log()[0]
    assert row["auto"] is True and row["status"] == "applied"
    assert row["verb"] == AUTO_VERB


def test_duplicate_url_skipped(harness):
    run(actions.auto(actions.Auto(
        verb=AUTO_VERB, args={"url": "https://x.test/r/page"})))
    # exact repeat, and trivially restyled variants, all dedup against the audit log
    for u in ("https://x.test/r/page", "HTTPS://X.TEST/r/page", "https://x.test/r/page/#step-2"):
        r = run(actions.auto(actions.Auto(verb=AUTO_VERB, args={"url": u})))
        assert r["ok"] is True and r["skipped"] == "duplicate"
    assert len(harness) == 1                   # executed exactly once
    assert len([r for r in astore.recent_log() if r["auto"]]) == 1


def test_failed_execution_audited_not_deduped(monkeypatch, harness):
    async def failing(args):
        harness.append(args)
        return {"ok": False, "error": "scrape failed"}

    with monkeypatch.context() as m:
        m.setitem(actions.EXECUTORS, AUTO_VERB, failing)
        r = run(actions.auto(actions.Auto(
            verb=AUTO_VERB, args={"url": "https://x.test/r/flaky"})))
        assert r["ok"] is False
        assert astore.recent_log()[0]["status"] == "failed"
        r2 = run(actions.auto(actions.Auto(
            verb=AUTO_VERB, args={"url": "https://x.test/r/flaky"})))
    assert "skipped" not in r2
    assert len(harness) == 2


def test_flag_flip_regates(monkeypatch, harness):
    monkeypatch.setitem(spec.SPEC[AUTO_VERB], "autonomous", False)
    r = run(actions.auto(actions.Auto(
        verb=AUTO_VERB, args={"url": "https://x.test/r/page"})))
    assert r["ok"] is False and r.get("rejected") is True
    assert harness == []
