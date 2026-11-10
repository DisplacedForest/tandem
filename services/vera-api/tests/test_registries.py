import ast
import asyncio
import os
import tempfile
from collections.abc import Iterator
from typing import Any

import pytest

import main
from routers import (action_registry, action_spec, actions, groom_common, knowledge_actions,
                     media_store, scheduler, vein_engine)

ROUTERS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "routers")

CAPABILITY_MODULES = {
    "kitchen", "knowledge_store", "media_store", "overseerr", "groom_common", "authoring",
    "updates", "home", "home_model", "home_reconcile", "conversation_extract", "learn",
    "knowledge_groom", "knowledge_actions", "media_curation",
}

VERBS = {
    "authoring.skill_upsert", "ha.service", "knowledge.set", "knowledge.delete",
    "knowledge.reverify", "knowledge.promote", "kitchen.grocy_adjust", "kitchen.mealie_import",
    "health.check", "overseerr_request", "docker.update",
}

JOBS = {
    "pulse", "home_model", "home_reconcile", "home_digest", "conversation_extract",
    "weight_fit", "knowledge_groom",
}


def _load_built_in_blocks() -> None:
    saved = vein_engine.BLOCKS_DIR
    vein_engine.BLOCKS_DIR = os.path.join(tempfile.mkdtemp(), "missing-blocks")
    try:
        vein_engine.load_block_modules()
    finally:
        vein_engine.BLOCKS_DIR = saved


_load_built_in_blocks()


def _imported_names(path: str) -> set[str]:
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read())
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.update(alias.name.split("."))
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                names.update(node.module.split("."))
            for alias in node.names:
                names.add(alias.name)
    return names


@pytest.mark.parametrize("module", ["actions.py", "action_spec.py", "scheduler.py"])
def test_core_modules_import_no_capability(module: str) -> None:
    assert _imported_names(os.path.join(ROUTERS, module)) & CAPABILITY_MODULES == set()


def test_registry_tables_keep_their_identity() -> None:
    assert action_spec.SPEC is action_registry.SPEC
    assert actions.EXECUTORS is action_registry.EXECUTORS


async def _noop(args: dict) -> dict:
    return {"ok": True}


async def _noop_job() -> dict:
    return {"ok": True}


def _validate(args: dict) -> str | None:
    return None


def _preview(args: dict) -> str:
    return "noop"


def _snapshot() -> tuple[list[tuple[str, Any]], list[tuple[str, Any]], dict[str, int]]:
    return list(action_registry.SPEC.items()), list(action_registry.EXECUTORS.items()), dict(action_registry.ORDER)


@pytest.fixture
def throwaway_verbs() -> Iterator[list[str]]:
    verbs: list[str] = []
    yield verbs
    for verb in verbs:
        action_registry.unregister_action(verb)


@pytest.fixture
def throwaway_jobs() -> Iterator[list[str]]:
    jobs: list[str] = []
    yield jobs
    for job in jobs:
        scheduler.unregister_job(job)


def test_duplicate_verb_raises() -> None:
    before = _snapshot()
    with pytest.raises(ValueError):
        action_registry.register_action(
            "kitchen.mealie_import", validate=_validate, preview=_preview, risk="low",
            reversible=True, autonomous=False, order=1, executor=_noop)
    assert _snapshot() == before


def test_duplicate_job_raises() -> None:
    before = list(scheduler.REGISTRY.items())
    with pytest.raises(ValueError):
        scheduler.register_job("pulse", "Another pulse", "0 1 * * *", _noop_job, order=1)
    assert list(scheduler.REGISTRY.items()) == before


@pytest.mark.parametrize("risk,reversible", [("high", True), ("low", False), ("medium", True)])
def test_unsafe_autonomous_verb_is_refused(risk: str, reversible: bool, throwaway_verbs: list[str]) -> None:
    throwaway_verbs.append("zz.unsafe")
    before = _snapshot()
    with pytest.raises(AssertionError, match="cannot be autonomous"):
        action_registry.register_action(
            "zz.unsafe", validate=_validate, preview=_preview, risk=risk,
            reversible=reversible, autonomous=True, order=5, executor=_noop)
    assert _snapshot() == before


def test_verbs_iterate_by_order_not_registration(throwaway_verbs: list[str]) -> None:
    for verb, order in (("zz.third", 1_000_030), ("zz.first", 1_000_010), ("zz.second", 1_000_020),
                        ("zz.early", 5)):
        throwaway_verbs.append(verb)
        action_registry.register_action(
            verb, validate=_validate, preview=_preview, risk="none", reversible=True,
            autonomous=False, order=order, executor=_noop)
    spec_order = list(action_spec.SPEC)
    assert spec_order[-3:] == ["zz.first", "zz.second", "zz.third"]
    assert spec_order[0] == "zz.early"
    assert list(actions.EXECUTORS)[-3:] == ["zz.first", "zz.second", "zz.third"]
    assert list(actions.EXECUTORS)[0] == "zz.early"


def test_jobs_iterate_by_order_not_registration(throwaway_jobs: list[str]) -> None:
    for job, order in (("zz_third", 1_000_030), ("zz_first", 1_000_010), ("zz_second", 1_000_020),
                       ("zz_early", 1)):
        throwaway_jobs.append(job)
        scheduler.register_job(job, job, "0 1 * * *", _noop_job, order=order)
    job_order = list(scheduler.REGISTRY)
    assert job_order[-3:] == ["zz_first", "zz_second", "zz_third"]
    assert job_order[0] == "zz_early"


def test_job_gate_registers_with_the_job(throwaway_jobs: list[str]) -> None:
    throwaway_jobs.append("zz_gated")
    scheduler.register_job("zz_gated", "Gated", "0 1 * * *", _noop_job, order=1_000_040,
                           gate=lambda: "closed")
    assert scheduler._gate_reason("zz_gated") == "closed"


def test_startup_registers_every_verb_and_job() -> None:
    assert "actions" in main.CAPABILITIES
    assert VERBS <= set(action_spec.SPEC)
    assert VERBS <= set(actions.EXECUTORS)
    assert JOBS <= set(scheduler._registry())


@pytest.fixture
def decision_stores(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> None:
    monkeypatch.setattr(media_store, "DB_PATH", str(tmp_path / "media.db"))
    monkeypatch.setattr(groom_common, "DB_PATH", str(tmp_path / "groom.db"))


def test_skip_records_the_media_decision(decision_stores: None) -> None:
    item = {"title": "Arrival", "media_type": "movie", "tmdb_id": 329865,
            "action": {"verb": "overseerr_request", "args": {}}, "state": "pending"}
    res = asyncio.run(actions._apply_item(item, "skip"))
    assert res == {"ok": True, "state": "skipped"}
    assert item["state"] == "skipped"
    assert [(r["media_type"], r["tmdb_id"], r["reason"]) for r in media_store.all()] == [
        ("movie", 329865, "skipped")]


def test_skip_without_media_ids_records_nothing(decision_stores: None) -> None:
    item = {"title": "x", "media_type": "movie", "tmdb_id": None,
            "action": {"verb": "overseerr_request", "args": {}}, "state": "pending"}
    asyncio.run(actions._apply_item(item, "skip"))
    assert media_store.all() == []


def test_skipping_a_promotion_suppresses_it(decision_stores: None) -> None:
    item = {"title": "Codify appliance", "action": {"verb": "knowledge.promote",
                                                    "args": {"type": "appliance"}},
            "state": "pending"}
    asyncio.run(actions._apply_item(item, "skip"))
    assert groom_common.is_suppressed("knowledge", "promote", "appliance")


def test_skip_side_effects_run_media_first(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[Any, ...]] = []
    seen_states: list[str] = []

    def record(media_type: str, tmdb_id: int, title: str, reason: str) -> None:
        seen_states.append(item["state"])
        calls.append(("media", media_type, tmdb_id, title, reason))

    def suppress(store: str, op_type: str, identity: str, reason: str = "") -> str:
        calls.append(("suppress", store, op_type, identity, reason))
        return ""

    monkeypatch.setattr(media_store, "record", record)
    monkeypatch.setattr(knowledge_actions.gcm, "suppress", suppress)
    item: dict = {"title": "T", "media_type": "tv", "tmdb_id": 7,
                  "action": {"verb": "knowledge.promote", "args": {"type": "pet"}}, "state": "pending"}
    asyncio.run(actions._apply_item(item, "skip"))
    assert calls == [("media", "tv", 7, "T", "skipped"),
                     ("suppress", "knowledge", "promote", "pet", "flagged proposal rejected")]
    assert seen_states == ["skipped"]


def test_approve_records_only_on_success(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[Any, ...]] = []
    seen_states: list[str] = []
    outcome: dict[str, Any] = {"result": {"ok": True}}

    async def run_token(token: str) -> dict:
        return outcome

    def record(media_type: str, tmdb_id: int, title: str, reason: str) -> None:
        seen_states.append(item["state"])
        calls.append((media_type, tmdb_id, title, reason))

    monkeypatch.setattr(actions, "_run_token", run_token)
    monkeypatch.setattr(media_store, "record", record)
    item: dict = {"title": "Dune", "media_type": "movie", "tmdb_id": 438631,
                  "action": {"verb": "overseerr_request", "args": {}, "token": "t"}, "state": "pending"}
    res = asyncio.run(actions._apply_item(item, "approve"))
    assert res["state"] == "approved"
    assert calls == [("movie", 438631, "Dune", "approved")]
    assert seen_states == ["approved"]

    outcome["result"] = {"ok": False, "error": "nope"}
    item["state"] = "pending"
    res = asyncio.run(actions._apply_item(item, "approve"))
    assert res == {"ok": False, "state": "pending", "error": "nope"}
    assert len(calls) == 1


def _fresh(script: str) -> None:
    import pathlib
    import subprocess
    import sys

    root = pathlib.Path(__file__).resolve().parents[1]
    result = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


ORDERED_VERBS = ("authoring.skill_upsert", "ha.service", "knowledge.set", "knowledge.delete", "knowledge.reverify",
         "knowledge.promote", "kitchen.grocy_adjust", "kitchen.mealie_import", "health.check",
         "overseerr_request", "docker.update")
ORDERED_JOBS = ("pulse", "home_model", "home_reconcile", "home_digest", "conversation_extract", "weight_fit",
        "knowledge_groom")


def test_actions_alone_serves_the_full_catalog_in_order() -> None:
    _fresh(
        "import asyncio, sys\n"
        "from routers import actions\n"
        "assert 'main' not in sys.modules\n"
        "out = asyncio.run(actions.registry())\n"
        "assert list(out) == ['verbs', 'ha_allowlist'], list(out)\n"
        f"assert [v['verb'] for v in out['verbs']] == list({ORDERED_VERBS!r}), out['verbs']\n"
        f"assert list(actions.EXECUTORS) == list({ORDERED_VERBS!r})\n"
        "assert 'main' not in sys.modules\n"
    )


def test_actions_alone_stages_a_verb_owned_elsewhere() -> None:
    _fresh(
        "from routers import actions\n"
        "ok, err = actions._stage('nope.verb', {}, 'test', 'test', None, None)\n"
        "assert ok is None and err['error'] == 'unknown verb nope.verb', err\n"
        "ok, err = actions._stage('knowledge.reverify', {}, 'test', 'test', None, None)\n"
        "assert err is not None and err['error'] != 'unknown verb knowledge.reverify', err\n"
        "ok, err = actions._stage('docker.update', {}, 'test', 'test', None, None)\n"
        "assert err is not None and err['error'] != 'unknown verb docker.update', err\n"
    )


def test_autonomy_lookup_alone_sees_every_verb() -> None:
    _fresh(
        "from routers import action_spec\n"
        "assert action_spec.is_autonomous('kitchen.mealie_import') is True\n"
        "assert action_spec.is_autonomous('docker.update') is False\n"
        f"assert list(action_spec.SPEC) == list({ORDERED_VERBS!r})\n"
    )


def test_decision_hooks_run_when_only_actions_is_imported() -> None:
    _fresh(
        "import asyncio\n"
        "from routers import actions\n"
        "seen = []\n"
        "item = {'media_type': 'movie', 'tmdb_id': 7, 'title': 'T',\n"
        "        'action': {'verb': 'knowledge.promote', 'args': {'type': 'appliance'}}}\n"
        "import routers.media_store as ms, routers.groom_common as gc\n"
        "ms.record = lambda *a: seen.append(('media',) + a)\n"
        "gc.suppress = lambda *a, **k: seen.append(('suppress',) + a)\n"
        "out = asyncio.run(actions._apply_item(item, 'skip'))\n"
        "assert out == {'ok': True, 'state': 'skipped'}, out\n"
        "assert seen == [('media', 'movie', 7, 'T', 'skipped'),\n"
        "                ('suppress', 'knowledge', 'promote', 'appliance')], seen\n"
    )


def test_scheduler_alone_knows_every_built_in_job() -> None:
    _fresh(
        "import sys\n"
        "from routers import scheduler\n"
        "assert 'main' not in sys.modules\n"
        f"assert [j for j in scheduler._registry() if not j.startswith('vein_')] == list({ORDERED_JOBS!r})\n"
        "reason = scheduler._gate_reason('home_model')\n"
        "assert reason and 'home_modeling' in reason, reason\n"
        "assert scheduler._gate_reason('pulse') is None\n"
        f"assert list(scheduler.builtin_jobs()) == list({ORDERED_JOBS!r})\n"
    )


def test_gate_lookup_first_still_finds_the_gate() -> None:
    _fresh(
        "from routers import scheduler\n"
        "reason = scheduler._gate_reason('home_digest')\n"
        "assert reason and 'home_modeling' in reason, reason\n"
    )


def test_workflow_trigger_alone_recognizes_built_in_jobs() -> None:
    _fresh(
        "from routers import workflow_triggers\n"
        "assert workflow_triggers.job_for('pulse') == 'pulse'\n"
        "assert workflow_triggers.job_for('knowledge_groom') == 'knowledge_groom'\n"
        "assert workflow_triggers.job_for('not_a_job') is None\n"
    )


def test_importing_main_registers_everything_without_the_lifespan() -> None:
    _fresh(
        "import main\n"
        "from routers import actions, scheduler\n"
        f"assert list(actions.EXECUTORS) == list({ORDERED_VERBS!r})\n"
        f"assert list(scheduler.REGISTRY) == list({ORDERED_JOBS!r})\n"
    )


def test_each_owner_imports_alone() -> None:
    for name in ("authoring", "conversation_extract", "home", "home_model", "home_reconcile", "kitchen",
                 "knowledge_actions", "knowledge_groom", "learn", "media_curation", "overseerr", "pulse",
                 "updates", "actions", "scheduler", "action_spec", "builtin_capabilities"):
        _fresh(f"import routers.{name}\n")


def test_a_second_thread_waits_for_the_load_instead_of_reading_empty_tables() -> None:
    _fresh(
        "import builtins, threading\n"
        "from routers import builtin_capabilities, scheduler\n"
        "paused, release, attempted = threading.Event(), threading.Event(), threading.Event()\n"
        "real_import = builtins.__import__\n"
        "def slow_import(name, globals=None, locals=None, fromlist=(), level=0):\n"
        "    if level == 1 and fromlist and 'authoring' in fromlist and not paused.is_set():\n"
        "        paused.set()\n"
        "        assert release.wait(120)\n"
        "    return real_import(name, globals, locals, fromlist, level)\n"
        "class Watched:\n"
        "    def __init__(self, inner):\n"
        "        self.inner = inner\n"
        "    def __enter__(self):\n"
        "        if threading.current_thread().name == 'reader':\n"
        "            attempted.set()\n"
        "        return self.inner.__enter__()\n"
        "    def __exit__(self, *exc):\n"
        "        return self.inner.__exit__(*exc)\n"
        "builtin_capabilities._lock = Watched(builtin_capabilities._lock)\n"
        "builtins.__import__ = slow_import\n"
        "loader = threading.Thread(target=builtin_capabilities.load, name='loader')\n"
        "loader.start()\n"
        "assert paused.wait(120)\n"
        "seen = {}\n"
        "def read():\n"
        "    seen['jobs'] = list(scheduler.builtin_jobs())\n"
        "    seen['gate'] = scheduler._gate_reason('home_model')\n"
        "reader = threading.Thread(target=read, name='reader')\n"
        "reader.start()\n"
        "assert attempted.wait(120)\n"
        "reader.join(0.2)\n"
        "assert reader.is_alive() and not seen, seen\n"
        "release.set()\n"
        "loader.join(120)\n"
        "reader.join(120)\n"
        "builtins.__import__ = real_import\n"
        "assert not loader.is_alive() and not reader.is_alive()\n"
        f"assert seen['jobs'] == list({ORDERED_JOBS!r}), seen\n"
        "assert seen['gate'] and 'home_modeling' in seen['gate'], seen\n"
    )


_FAIL_THEN_RETRY = (
    "from routers import action_registry, builtin_capabilities, scheduler\n"
    "real = action_registry.register_action\n"
    "calls = {'n': 0, 'limit': FAIL_AT}\n"
    "def flaky(verb, **kw):\n"
    "    real(verb, **kw)\n"
    "    calls['n'] += 1\n"
    "    if calls['n'] == calls['limit']:\n"
    "        raise RuntimeError('boom')\n"
    "action_registry.register_action = flaky\n"
    "for attempt, reader in enumerate((builtin_capabilities.load, scheduler.builtin_jobs,\n"
    "                                  action_registry.load_builtin)):\n"
    "    calls['n'] = 0\n"
    "    calls['limit'] = FAIL_AT if attempt == 0 else 1\n"
    "    try:\n"
    "        reader()\n"
    "    except RuntimeError as e:\n"
    "        assert str(e) == 'boom'\n"
    "    else:\n"
    "        raise AssertionError('a failed load must surface to every reader')\n"
    "action_registry.register_action = real\n"
    "builtin_capabilities.load()\n"
)


def _retry_script(preimport: str, fail_at: int) -> str:
    return (
        preimport + _FAIL_THEN_RETRY.replace("FAIL_AT", str(fail_at))
        + f"assert list(action_registry.SPEC) == list({ORDERED_VERBS!r}), list(action_registry.SPEC)\n"
        + f"assert list(action_registry.EXECUTORS) == list({ORDERED_VERBS!r})\n"
        + f"assert list(scheduler.REGISTRY) == list({ORDERED_JOBS!r}), list(scheduler.REGISTRY)\n"
        + "assert list(scheduler.GATES) == ['home_model', 'home_reconcile', 'home_digest']\n"
        + "assert len(action_registry.ITEM_DECISION_HOOKS) == 2, action_registry.ITEM_DECISION_HOOKS\n"
        + "assert list(action_registry.CATALOG_EXTRAS) == ['ha_allowlist']\n"
    )


@pytest.mark.parametrize("fail_at", [1, 2, 3, 5, 8, 11])
def test_a_load_that_fails_midway_surfaces_and_the_retry_completes(fail_at: int) -> None:
    _fresh(_retry_script("", fail_at))


@pytest.mark.parametrize("first", ["home", "kitchen", "knowledge_actions", "media_curation", "pulse"])
def test_retry_completes_when_an_owner_was_imported_before_the_failed_load(first: str) -> None:
    _fresh(_retry_script(f"import routers.{first}\n", 2))


def test_the_same_owner_may_register_again_and_another_owner_may_not(throwaway_verbs: list[str]) -> None:
    throwaway_verbs.append("zz.repeat")
    action_registry.register_action(
        "zz.repeat", validate=_validate, preview=_preview, risk="low",
        reversible=True, autonomous=False, order=990, executor=_noop)
    action_registry.register_action(
        "zz.repeat", validate=_validate, preview=_preview, risk="none",
        reversible=True, autonomous=False, order=991, executor=_noop)
    assert action_registry.SPEC["zz.repeat"]["risk"] == "none"
    assert list(action_registry.SPEC).count("zz.repeat") == 1

    async def foreign(args: dict) -> dict:
        return {}

    foreign.__module__ = "somewhere.else"
    with pytest.raises(ValueError):
        action_registry.register_action(
            "zz.repeat", validate=_validate, preview=_preview, risk="low",
            reversible=True, autonomous=False, order=992, executor=foreign)
    assert action_registry.SPEC["zz.repeat"]["risk"] == "none"


def test_gate_table_order_does_not_depend_on_what_is_imported_first() -> None:
    for first in ("home_reconcile", "home_model", "scheduler"):
        _fresh(
            f"import routers.{first}\n"
            "from routers import scheduler\n"
            "scheduler.builtin_jobs()\n"
            "assert list(scheduler.GATES) == ['home_model', 'home_reconcile', 'home_digest'], list(scheduler.GATES)\n"
        )


_WRITER_RACE = (
    "import threading\n"
    "from routers import action_registry, scheduler\n"
    "paused, release, attempted = threading.Event(), threading.Event(), threading.Event()\n"
    "class Watched:\n"
    "    def __init__(self, inner):\n"
    "        self.inner = inner\n"
    "    def __enter__(self):\n"
    "        if threading.current_thread().name == 'second':\n"
    "            attempted.set()\n"
    "        return self.inner.__enter__()\n"
    "    def __exit__(self, *exc):\n"
    "        return self.inner.__exit__(*exc)\n"
)


def test_two_threads_registering_actions_both_keep_their_entries() -> None:
    _fresh(
        _WRITER_RACE
        + "action_registry._write_lock = Watched(action_registry._write_lock)\n"
        "real_resort = action_registry._resort\n"
        "def slow_resort():\n"
        "    if threading.current_thread().name == 'first' and not paused.is_set():\n"
        "        paused.set()\n"
        "        assert release.wait(120)\n"
        "    real_resort()\n"
        "action_registry._resort = slow_resort\n"
        "async def run(args):\n"
        "    return {}\n"
        "def add(verb, order):\n"
        "    action_registry.register_action(verb, validate=lambda a: None, preview=lambda a: verb,\n"
        "                                    risk='low', reversible=True, autonomous=False,\n"
        "                                    order=order, executor=run)\n"
        "first = threading.Thread(target=add, args=('zz.first', 2), name='first')\n"
        "second = threading.Thread(target=add, args=('zz.second', 1), name='second')\n"
        "first.start()\n"
        "assert paused.wait(120)\n"
        "second.start()\n"
        "assert attempted.wait(120)\n"
        "second.join(0.2)\n"
        "assert second.is_alive() and 'zz.second' not in action_registry.SPEC\n"
        "release.set()\n"
        "first.join(120)\n"
        "second.join(120)\n"
        "assert not first.is_alive() and not second.is_alive()\n"
        "assert list(action_registry.SPEC) == ['zz.second', 'zz.first'], list(action_registry.SPEC)\n"
        "assert list(action_registry.EXECUTORS) == ['zz.second', 'zz.first']\n"
    )


def test_two_threads_registering_jobs_both_keep_their_entries() -> None:
    _fresh(
        _WRITER_RACE
        + "scheduler._write_lock = Watched(scheduler._write_lock)\n"
        "real_reorder = scheduler._reorder\n"
        "def slow_reorder():\n"
        "    if threading.current_thread().name == 'first' and not paused.is_set():\n"
        "        paused.set()\n"
        "        assert release.wait(120)\n"
        "    real_reorder()\n"
        "scheduler._reorder = slow_reorder\n"
        "async def run():\n"
        "    return {}\n"
        "def gate():\n"
        "    return 'closed'\n"
        "def add(job, order):\n"
        "    scheduler.register_job(job, job, '0 1 * * *', run, order=order, gate=gate)\n"
        "first = threading.Thread(target=add, args=('zz_first', 2), name='first')\n"
        "second = threading.Thread(target=add, args=('zz_second', 1), name='second')\n"
        "first.start()\n"
        "assert paused.wait(120)\n"
        "second.start()\n"
        "assert attempted.wait(120)\n"
        "second.join(0.2)\n"
        "assert second.is_alive() and 'zz_second' not in scheduler.REGISTRY\n"
        "release.set()\n"
        "first.join(120)\n"
        "second.join(120)\n"
        "assert not first.is_alive() and not second.is_alive()\n"
        "assert list(scheduler.REGISTRY) == ['zz_second', 'zz_first'], list(scheduler.REGISTRY)\n"
        "assert list(scheduler.GATES) == ['zz_second', 'zz_first']\n"
    )


def test_an_owner_imported_in_another_thread_during_a_load_is_not_lost() -> None:
    _fresh(
        "import threading\n"
        "from routers import action_registry, builtin_capabilities, scheduler\n"
        "paused, release = threading.Event(), threading.Event()\n"
        "real_resort = action_registry._resort\n"
        "def slow_resort():\n"
        "    if threading.current_thread().name == 'importer' and not paused.is_set():\n"
        "        paused.set()\n"
        "        assert release.wait(120)\n"
        "    real_resort()\n"
        "action_registry._resort = slow_resort\n"
        "def import_home():\n"
        "    import routers.home\n"
        "importer = threading.Thread(target=import_home, name='importer')\n"
        "importer.start()\n"
        "assert paused.wait(120)\n"
        "loader = threading.Thread(target=builtin_capabilities.load, name='loader')\n"
        "loader.start()\n"
        "loader.join(0.5)\n"
        "release.set()\n"
        "importer.join(120)\n"
        "loader.join(120)\n"
        "assert not importer.is_alive() and not loader.is_alive()\n"
        f"assert list(action_registry.SPEC) == list({ORDERED_VERBS!r}), list(action_registry.SPEC)\n"
        f"assert list(action_registry.EXECUTORS) == list({ORDERED_VERBS!r})\n"
        f"assert list(scheduler.REGISTRY) == list({ORDERED_JOBS!r}), list(scheduler.REGISTRY)\n"
        "assert list(action_registry.CATALOG_EXTRAS) == ['ha_allowlist']\n"
    )
