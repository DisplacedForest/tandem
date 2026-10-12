import asyncio
import json

import pytest
from pydantic import ValidationError

from routers import inference_admission, integrations, model_client, task_document as document
from routers.task_runtime import Dispatcher
from routers.task_store import TaskStore, encode


PAYLOAD = {"title": "A document", "brief": "Explain the supplied material.", "inputs": ["A supplied fact."], "max_sections": 2}
OUTLINE = {"sections": [{"heading": "First", "instructions": "Explain the fact."},
                         {"heading": "Second", "instructions": "Draw a conclusion."}]}


@pytest.fixture
def model(monkeypatch):
    calls = []
    responses = [OUTLINE, {"text": "First draft"}, {"text": "Second draft"},
                 {"text": "First revision"}, {"text": "Second revision"}]

    async def complete(messages, **kwargs):
        calls.append((messages, kwargs, inference_admission.priority_context.get()))
        value = responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return value if isinstance(value, str) else json.dumps(value)

    monkeypatch.setattr(document.integrations, "integration", lambda _: {"url": "https://model.invalid/v1", "model": "fixture"})
    monkeypatch.setattr(document.model_client, "complete_text", complete)
    monkeypatch.setenv("STRUCTURED_REPAIR_ATTEMPTS", "1")
    return calls, responses


@pytest.fixture
def store(tmp_path):
    return TaskStore(str(tmp_path / "tasks.db"))


def create(store, payload=None):
    return store.create("document", payload or PAYLOAD, "create-document", document.validate_payload)


async def advance(store):
    task = store.claim(("document",))
    assert task is not None
    result = await document.step(task)
    return store.commit_step(task["id"], task["generation"], result)


async def until(store, task_id, state):
    async with asyncio.timeout(3):
        while True:
            current = store.get(task_id)
            if current["state"] == state:
                return current
            await asyncio.sleep(0.005)


def test_dispatcher_sequences_checkpointed_sections_and_typed_result(store, model):
    async def run():
        task = create(store)
        runtime = Dispatcher(store, poll_seconds=0.005)
        runtime.register("document", document.step, document.STEP_TIMEOUT_SECONDS + 5, document.TOOLS)
        await runtime.start()
        try:
            finished = await until(store, task["id"], "completed")
        finally:
            assert await runtime.stop()
        calls, responses = model
        assert not responses
        assert len(calls) == 5
        assert all(kwargs["priority"] == "background" and priority == "background" for _, kwargs, priority in calls)
        assert all(kwargs["max_tokens"] == document.MAX_TOKENS for _, kwargs, _ in calls)
        assert all("tools" not in kwargs for _, kwargs, _ in calls)
        assert finished["checkpoint"]["drafts"] == ["First draft", "Second draft"]
        assert finished["checkpoint"]["revisions"] == ["First revision", "Second revision"]
        assert finished["generation"] == 11
        markdown = "# A document\n\n## First\n\nFirst revision\n\n## Second\n\nSecond revision\n"
        assert finished["result"] == {"kind": "document_report", "title": "A document", "markdown": markdown,
            "spoken_text": "The document is ready.", "display_blocks": [{"type": "artifact", "artifact": {
                "id": task["id"], "title": "A document", "report": markdown, "sources": []}}]}
        events = store.events(task_id=task["id"])
        progress = [event["data"] for event in events if event["kind"] == "progress"]
        assert progress[-1] == {"phase": "assemble", "sources_count": 1, "sections_count": 2,
                                "sections_drafted": 2, "sections_revised": 2}
        assert sum(event["kind"] == "completed" for event in events) == 1
        assert "supplied fact" not in json.dumps(progress)
        encode(finished["result"])
        encode(finished["checkpoint"])
    asyncio.run(run())


@pytest.mark.parametrize("field,value", [("brief", " "), ("brief", "x" * 5001), ("title", "x" * 201),
    ("title", "Two\nlines"), ("title", "\ud800"), ("inputs", ["x"] * 9), ("inputs", ["x" * 4001]),
    ("max_sections", 7), ("max_sections", True), ("native_binding", {}), ("tools", ["search"])])
def test_payload_is_strict_and_bounded(field, value, model):
    with pytest.raises(ValidationError):
        document.validate_payload({**PAYLOAD, field: value})
    assert not model[0]


@pytest.mark.parametrize("checkpoint", [
    {"phase": "draft"}, {"drafts": ["orphan"]}, {"revisions": ["orphan"]},
    {"phase": "assemble", "outline": OUTLINE["sections"]}, {"expected_generation": True},
    {"outline": OUTLINE["sections"]}, {"phase": "gather"}, {"unknown": 1}])
def test_checkpoint_refuses_invalid_sequence(checkpoint, model):
    with pytest.raises(ValidationError):
        asyncio.run(document.step({"id": "fixture", "generation": 1, "payload": PAYLOAD, "checkpoint": checkpoint}))
    assert not model[0]


@pytest.mark.parametrize("disabled", [False, True])
def test_unconfigured_or_disabled_integration_never_calls_model(monkeypatch, store, disabled):
    monkeypatch.setattr(integrations.store, "load", lambda: {"model": {"enabled": False}} if disabled else {})
    monkeypatch.setenv("VERA_BASE", "https://model.invalid/v1" if disabled else "")
    monkeypatch.setenv("VERA_MODEL", "fixture" if disabled else "")
    calls = []

    async def forbidden(*args, **kwargs):
        calls.append(True)
        raise AssertionError("No model call is allowed")

    monkeypatch.setattr(model_client, "complete_text", forbidden)

    async def run():
        create(store)
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert "Enable and configure" in waiting["decision"]["prompt"]
        assert waiting["checkpoint"]["retry"]
        assert not calls
    asyncio.run(run())


def test_recovery_requires_explicit_retry_and_preserves_completed_sections(store, model):
    async def run():
        task = create(store)
        for _ in range(5):
            await advance(store)
        assert len(model[0]) == 2
        abandoned = store.claim(("document",))
        assert abandoned["checkpoint"]["drafts"] == ["First draft"]
        assert store.recover() == 1
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert len(model[0]) == 2
        assert waiting["checkpoint"]["drafts"] == ["First draft"]
        assert "repeat model usage" in waiting["decision"]["prompt"]
        store.respond(task["id"], waiting["decision"]["id"], "wrong", {"action": "continue"})
        again = await advance(store)
        assert again["state"] == "needs_decision"
        assert len(model[0]) == 2
        decision_id = again["decision"]["id"]
        store.respond(task["id"], decision_id, "retry", {"action": "retry"})
        store.respond(task["id"], decision_id, "retry", {"action": "retry"})
        prepared = await advance(store)
        assert prepared["checkpoint"]["expected_generation"] == prepared["generation"] + 1
        assert len(model[0]) == 2
        while store.get(task["id"])["state"] == "queued":
            await advance(store)
        finished = store.get(task["id"])
        assert finished["state"] == "completed"
        assert len(model[0]) == 5
        assert finished["checkpoint"]["drafts"] == ["First draft", "Second draft"]
    asyncio.run(run())


def test_clean_prepared_restart_keeps_expected_generation(store, model):
    async def run():
        task = create(store)
        prepared = await advance(store)
        reopened = TaskStore(store.path)
        assert reopened.recover() == 0
        assert reopened.get(task["id"])["checkpoint"] == prepared["checkpoint"]
        advanced = await advance(reopened)
        assert advanced["checkpoint"]["phase"] == "draft"
        assert len(model[0]) == 1
    asyncio.run(run())


@pytest.mark.parametrize("response", [RuntimeError("private provider diagnostic"), "x" * 65537, "\ud800"])
def test_model_failure_is_explicit_and_does_not_leak_error_or_retry(store, model, response):
    async def run():
        model[1][:] = [response]
        create(store)
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert len(model[0]) == 1
        assert "private provider" not in json.dumps(waiting)
        assert waiting["checkpoint"]["expected_generation"] is None
    asyncio.run(run())


def test_structured_repair_is_bounded_and_retains_valid_sections(store, model, monkeypatch):
    async def run():
        create(store)
        await advance(store)
        await advance(store)
        model[1][:] = [{"text": "x" * 3001}, {"text": "fixed draft"}]
        await advance(store)
        repaired = await advance(store)
        assert repaired["checkpoint"]["drafts"] == ["fixed draft"]
        assert "previous reply was not usable" in model[0][-1][0][-1]["content"]
        monkeypatch.setenv("STRUCTURED_REPAIR_ATTEMPTS", "100000")
        model[1][:] = ["bad", "bad", "bad"]
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert waiting["checkpoint"]["drafts"] == ["fixed draft"]
        assert len(model[0]) == 6
    asyncio.run(run())


def test_total_deadline_includes_repairs(store, model, monkeypatch):
    async def run():
        calls = []
        canceled = asyncio.Event()

        async def delayed(messages, **kwargs):
            calls.append(messages)
            if len(calls) == 1:
                return "invalid"
            try:
                await asyncio.Event().wait()
            finally:
                canceled.set()

        monkeypatch.setattr(model_client, "complete_text", delayed)
        monkeypatch.setattr(document, "STEP_TIMEOUT_SECONDS", 0.03)
        create(store)
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert "time limit" in waiting["decision"]["prompt"]
        assert len(calls) == 2 and canceled.is_set()
    asyncio.run(run())


def test_cancel_running_dispatcher_preserves_prior_sections(store, model, monkeypatch):
    async def run():
        task = create(store)
        for _ in range(4):
            await advance(store)
        entered, release = asyncio.Event(), asyncio.Event()

        async def held(messages, **kwargs):
            entered.set()
            await release.wait()
            return json.dumps({"text": "Must not be saved"})

        monkeypatch.setattr(model_client, "complete_text", held)
        runtime = Dispatcher(store, poll_seconds=0.005)
        runtime.register("document", document.step, 1, document.TOOLS)
        await runtime.start()
        try:
            await asyncio.wait_for(entered.wait(), 1)
            assert store.cancel(task["id"])["cancel_requested"]
            release.set()
            canceled = await until(store, task["id"], "canceled")
            assert canceled["checkpoint"]["drafts"] == ["First draft"]
            assert canceled["result"] is None
            assert not any(event["kind"] == "completed" for event in store.events(task_id=task["id"]))
        finally:
            release.set()
            assert await runtime.stop()
    asyncio.run(run())


def test_dispatcher_shutdown_during_generation_pauses_on_restart(store, model, monkeypatch):
    async def run():
        task = create(store)
        entered, canceled = asyncio.Event(), asyncio.Event()

        async def held(messages, **kwargs):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                canceled.set()

        monkeypatch.setattr(model_client, "complete_text", held)
        runtime = Dispatcher(store, poll_seconds=0.005)
        runtime.register("document", document.step, 1, document.TOOLS)
        await runtime.start()
        await asyncio.wait_for(entered.wait(), 1)
        assert await runtime.stop()
        assert canceled.is_set()
        assert store.get(task["id"])["state"] == "queued"
        resumed = Dispatcher(store, poll_seconds=0.005)
        resumed.register("document", document.step, 1, document.TOOLS)
        await resumed.start()
        try:
            waiting = await until(store, task["id"], "needs_decision")
            assert "previous model request" in waiting["decision"]["prompt"]
        finally:
            assert await resumed.stop()
    asyncio.run(run())


def test_maximum_unicode_checkpoint_and_artifact_fit_store_limit(store):
    async def run():
        payload = {"title": "\U0001f330" * 200, "brief": "b", "max_sections": 6}
        checkpoint = document.Checkpoint(phase="assemble",
            outline=[document.Section(heading="\U0001f330" * 200, instructions="i" * 500) for _ in range(6)],
            drafts=["\U0001f330" * 3000] * 6, revisions=["\U0001f330" * 3000] * 6)
        result = await document.step({"id": "fixture", "generation": 1, "payload": payload,
                                      "checkpoint": checkpoint.model_dump()})
        assert result.state == "completed"
        encode(result.result)
        encode(result.checkpoint)
        assert result.result["markdown"].count("\U0001f330") == 19400
    asyncio.run(run())


def test_outline_cannot_exceed_requested_count(store, model):
    async def run():
        create(store, {**PAYLOAD, "max_sections": 1})
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert not waiting["checkpoint"]["outline"]
    asyncio.run(run())


@pytest.mark.parametrize("value,expected", [("nan", 30), ("inf", 30), ("-1", 30), ("0", 30),
                                            ("invalid", 30), ("99999", 90), ("15", 15)])
def test_environment_limits_are_finite_and_capped(monkeypatch, value, expected):
    monkeypatch.setenv("DOCUMENT_STEP_TIMEOUT_SECONDS", value)
    assert document._limit("DOCUMENT_STEP_TIMEOUT_SECONDS", 30, 90) == expected


def test_shared_model_client_uses_background_admission_and_releases_lease(store, monkeypatch):
    async def run():
        base = "https://model.invalid/v1"
        policy = inference_admission.AdmissionPolicy(store, inference_admission.Settings(
            background_seconds=0.5, cleanup_seconds=0.01, pending_seconds=1, poll_seconds=0.002))
        monkeypatch.setattr(inference_admission, "_policy", policy)
        monkeypatch.setattr(integrations, "integration", lambda _: {"url": base, "model": "fixture"})
        monkeypatch.setattr(model_client, "_main_kwargs", lambda _: None)
        requests = []
        request = policy.request

        def record(*args, **kwargs):
            requests.append(args)
            return request(*args, **kwargs)

        monkeypatch.setattr(policy, "request", record)
        posts = []

        async def post(url, body, timeout):
            posts.append((url, body, timeout))
            return {"choices": [{"message": {"content": json.dumps(OUTLINE)}}]}

        monkeypatch.setattr(model_client, "_post", post)
        task = create(store)
        await advance(store)
        advanced = await advance(store)
        assert advanced["checkpoint"]["phase"] == "draft"
        assert requests and all(args[2] == "background" for args in requests)
        assert posts[0][0] == base + "/chat/completions"
        assert posts[0][1]["max_tokens"] == document.MAX_TOKENS
        assert "tools" not in posts[0][1]
        assert 0 < posts[0][2] <= 0.5
        assert request(requests[0][0], requests[0][1], "background", document.STEP_TIMEOUT_SECONDS)["state"] == "released"
        assert store.get(task["id"])["state"] == "queued"
    asyncio.run(run())


def test_total_deadline_covers_waiting_for_shared_admission(store, monkeypatch):
    async def run():
        base = "https://model.invalid/v1"
        policy = inference_admission.AdmissionPolicy(store, inference_admission.Settings(
            background_seconds=1, cleanup_seconds=0.01, pending_seconds=1, poll_seconds=0.002))
        monkeypatch.setattr(inference_admission, "_policy", policy)
        monkeypatch.setattr(integrations, "integration", lambda _: {"url": base, "model": "fixture"})
        monkeypatch.setattr(model_client, "_main_kwargs", lambda _: None)
        monkeypatch.setattr(document, "STEP_TIMEOUT_SECONDS", 0.03)
        resource = inference_admission.endpoint_resource(base)
        assert policy.request("foreground", resource, "foreground", 1)["state"] == "admitted"
        posts = []

        async def post(*args):
            posts.append(args)
            raise AssertionError("The foreground lease must prevent this call")

        monkeypatch.setattr(model_client, "_post", post)
        create(store)
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert "time limit" in waiting["decision"]["prompt"]
        assert not posts
        policy.release("foreground")
    asyncio.run(run())


def test_integration_is_checked_again_before_repair(store, model, monkeypatch):
    async def run():
        calls = []
        enabled = [True]
        monkeypatch.setattr(integrations, "integration", lambda _: {"model": "fixture"} if enabled[0] else None)

        async def disables(messages, **kwargs):
            calls.append(messages)
            enabled[0] = False
            return "invalid"

        monkeypatch.setattr(model_client, "complete_text", disables)
        create(store)
        await advance(store)
        waiting = await advance(store)
        assert waiting["state"] == "needs_decision"
        assert "Enable and configure" in waiting["decision"]["prompt"]
        assert len(calls) == 1
    asyncio.run(run())


@pytest.mark.parametrize("change", ["disabled", "endpoint", "model", "unchanged"])
def test_queued_model_configuration_is_revalidated_before_outbound(store, monkeypatch, change):
    async def run():
        base = "https://original.invalid/v1"
        current = {"url": base, "model": "fixture"}
        policy = inference_admission.AdmissionPolicy(store, inference_admission.Settings(
            background_seconds=1, cleanup_seconds=0.01, pending_seconds=1, poll_seconds=0.002))
        monkeypatch.setattr(inference_admission, "_policy", policy)
        monkeypatch.setattr(integrations, "integration", lambda _: current or None)
        monkeypatch.setattr(model_client, "_main_kwargs", lambda _: None)
        resource = inference_admission.endpoint_resource(base)
        assert policy.request("foreground", resource, "foreground", 2)["state"] == "admitted"
        pending = asyncio.Event()
        loop = asyncio.get_running_loop()
        request = policy.request
        requests = []

        def observed(*args, **kwargs):
            result = request(*args, **kwargs)
            requests.append(args)
            if result["state"] == "pending" and args[2] == "background":
                loop.call_soon_threadsafe(pending.set)
            return result

        monkeypatch.setattr(policy, "request", observed)
        posts = []

        async def post(url, body, timeout):
            posts.append((url, body, timeout))
            return {"choices": [{"message": {"content": json.dumps(OUTLINE)}}]}

        monkeypatch.setattr(model_client, "_post", post)
        create(store)
        await advance(store)
        running = asyncio.create_task(advance(store))
        try:
            await asyncio.wait_for(pending.wait(), 1)
            if change == "disabled":
                current.clear()
            elif change == "endpoint":
                current["url"] = "https://replacement.invalid/v1"
            elif change == "model":
                current["model"] = "replacement"
            policy.release("foreground")
            outcome = await asyncio.wait_for(running, 1)
        finally:
            policy.release("foreground")
            if not running.done():
                running.cancel()
            await asyncio.gather(running, return_exceptions=True)
        if change == "unchanged":
            assert outcome["state"] == "queued"
            assert outcome["checkpoint"]["phase"] == "draft"
            assert len(posts) == 1 and posts[0][0] == base + "/chat/completions"
        else:
            assert outcome["state"] == "needs_decision"
            assert outcome["checkpoint"]["retry"]
            assert not posts
        for args in requests:
            assert request(args[0], args[1], "background", document.STEP_TIMEOUT_SECONDS)["state"] == "released"
    asyncio.run(run())


def test_prompt_budget_rejects_oversized_inputs_and_matches_production():
    oversized = {**PAYLOAD, "brief": "\u4e2d" * 5000, "inputs": ["\u4e2d" * 4000] * 8}
    with pytest.raises(ValueError):
        document.validate_payload(oversized)
    assert document.core.PROMPT_BYTES + document.core.PROMPT_HEADROOM <= 16384
    payload = document.core.DocumentPayload.model_validate({**PAYLOAD, "brief": "b" * 2000, "max_sections": 4})
    outline = [document.core.Section(heading="h" * 50, instructions="i" * 200) for _ in range(4)]
    checkpoint = document.core.Checkpoint(phase="revise", outline=outline, drafts=["d" * 3000] * 4, revisions=[])
    assert document.core.prompt_bytes(document.core._messages(payload, checkpoint)) <= document.core.PROMPT_BYTES


@pytest.mark.asyncio
async def test_oversized_outline_pauses_with_a_visible_explanation(store, model):
    calls, responses = model
    responses[0] = {"sections": [{"heading": "h" * 200, "instructions": "i" * 500} for _ in range(6)]}
    task = create(store, {**PAYLOAD, "brief": "b" * 5000, "inputs": ["x" * 2000], "max_sections": 6})
    await advance(store)
    await advance(store)
    current = await until(store, task["id"], "needs_decision")
    assert "too long" in current["decision"]["prompt"] and current["checkpoint"]["phase"] == "outline"


@pytest.mark.asyncio
async def test_revision_that_cannot_fit_keeps_the_draft_without_a_model_call(store, model, monkeypatch):
    calls, _ = model
    task = create(store, {**PAYLOAD, "brief": "short brief"})
    monkeypatch.setattr(document.core, "PROMPT_BYTES", 1200)
    outline = [{"heading": "First", "instructions": "Introduce the idea."}, {"heading": "Second", "instructions": "Draw a conclusion."}]
    drafts = ["d" * 1500, "e" * 1500]
    checkpoint = {"phase": "revise", "outline": outline, "drafts": drafts, "revisions": [], "expected_generation": None, "retry": False, "bullet_count": None}
    claimed = store.claim(("document",))
    store.commit_step(claimed["id"], claimed["generation"], document.core._progress(document.core.DocumentPayload.model_validate(claimed["payload"]), document.core.Checkpoint.model_validate(checkpoint)))
    before = len(calls)
    await advance(store)
    current = store.get(task["id"])
    assert current["checkpoint"]["revisions"] == ["d" * 1500] and len(calls) == before
    await advance(store)
    await advance(store)
    final = await until(store, task["id"], "completed")
    assert "d" * 1500 in final["result"]["markdown"] and "e" * 1500 in final["result"]["markdown"] and len(calls) == before
