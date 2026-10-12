import asyncio
import json

import pytest
from pydantic import ValidationError

from routers import research, task_research
from routers.websearch import SearchResponse, SearchResult


@pytest.fixture
def research_tools(monkeypatch):
    calls = []

    async def model(messages, **kwargs):
        if messages[0]["content"] == research.PLAN_SYS:
            calls.append("plan")
            return json.dumps({"subquestions": ["First?", "Second?"]})
        calls.append("synthesize")
        return "A supported finding [1]."

    async def search(request):
        calls.append(request.query)
        return SearchResponse(query=request.query, results=[SearchResult(
            title="Evidence", url="https://example.test/evidence", content="Evidence " * 500,
            rendered=False)])

    async def rag(query, errors):
        calls.append("rag")
        return [{"title": "Local evidence", "url": "local", "content": "Local finding"}]

    monkeypatch.setattr(research, "_vera", model)
    monkeypatch.setattr(research, "web_search", search)
    monkeypatch.setattr(research, "_rag_sources", rag)
    monkeypatch.delenv("RESEARCH_MAX_ITERATIONS", raising=False)
    return calls


def advance(task):
    result = asyncio.run(task_research.step(task))
    task["checkpoint"] = result.checkpoint
    task["decision_reply"] = None
    return result


def test_steps_bound_work_and_preserve_cited_artifact(research_tools):
    task = {"payload": {"query": "Question"}}
    plan = advance(task)
    assert plan.event == "progress"
    assert research_tools == ["plan"]
    first = advance(task)
    assert first.event == "source_found"
    assert first.data["sources"] == [{"n": 1, "title": "Evidence"}]
    assert "content" not in first.data["sources"][0]
    assert len(task["checkpoint"]["sources"][0]["content"]) == research.PER_SOURCE_CHARS
    assert research_tools == ["plan", "First?"]
    duplicate = advance(task)
    assert duplicate.event == "progress"
    assert len(task["checkpoint"]["sources"]) == 1
    assert research_tools == ["plan", "First?", "Second?"]
    local = advance(task)
    assert local.event == "source_found"
    assert research_tools[-1] == "rag"
    complete = advance(task)
    assert complete.state == "completed"
    assert complete.event == "completed"
    assert complete.result["report"] == "A supported finding [1]."
    assert complete.result["sources"] == [
        {"n": 1, "title": "Evidence", "url": "https://example.test/evidence"},
        {"n": 2, "title": "Local evidence", "url": "local"}]
    assert complete.result["errors"] == []


@pytest.mark.parametrize("payload", [
    {"query": " "}, {"query": "a" * 5001}, {"query": "Q", "subquestions": 6},
    {"query": "Q", "pages_per_q": -1}, {"query": "Q", "use_rag": "yes"},
    {"query": "Q", "collection_id": "unapproved"}])
def test_payload_validation_precedes_tools(payload, research_tools):
    with pytest.raises(ValidationError):
        advance({"payload": payload})
    assert research_tools == []


def test_no_sources_requires_explicit_retry(monkeypatch, research_tools):
    async def unavailable(request):
        raise RuntimeError("Search unavailable")

    monkeypatch.setattr(research, "web_search", unavailable)
    task = {"payload": {"query": "Q", "use_rag": False}}
    for _ in range(3):
        advance(task)
    waiting = advance(task)
    assert waiting.state == "needs_decision"
    assert waiting.result is None
    assert waiting.checkpoint["phase"] == "gather"
    assert waiting.checkpoint["next_query"] == 0
    assert any("Search unavailable" in error for error in waiting.checkpoint["errors"])
    assert research_tools == ["plan"]
    task["decision_reply"] = {"action": "continue"}
    assert advance(task).state == "needs_decision"
    assert research_tools == ["plan"]
    task["decision_reply"] = {"action": "retry"}
    assert advance(task).state == "queued"
    assert task["checkpoint"]["next_query"] == 1


@pytest.mark.parametrize("report", ["", "Uncited claim", "Bad reference [2]", "Bad reference [0]",
                                    "x" * 30001, "Bad reference [" + "9" * 5000 + "]", "\ud800 [1]"])
def test_bad_synthesis_retains_evidence_for_retry(monkeypatch, research_tools, report):
    task = {"payload": {"query": "Q", "subquestions": 1, "use_rag": False}}
    advance(task)
    advance(task)

    async def synthesize(*args):
        return report

    monkeypatch.setattr(research, "_synthesize", synthesize)
    waiting = advance(task)
    assert waiting.state == "needs_decision"
    assert waiting.result is None
    assert waiting.checkpoint["phase"] == "synthesize"
    assert len(waiting.checkpoint["sources"]) == 1

    async def repaired(*args):
        return "Fixed citation [1]."

    monkeypatch.setattr(research, "_synthesize", repaired)
    task["decision_reply"] = {"action": "retry"}
    assert advance(task).state == "completed"
    assert research_tools == ["plan", "First?"]


def test_source_and_error_storage_is_bounded():
    checkpoint = task_research.Checkpoint()
    candidates = [{"title": "a" * 500, "url": f"https://example.test/{i}", "content": "b" * 5000}
                  for i in range(20)]
    candidates.insert(0, {"title": "Unsafe", "url": "file:///etc/passwd", "content": "ignored"})
    candidates.insert(1, {"title": "Too long", "url": "https://example.test/" + "a" * 3000,
                          "content": "ignored"})
    task_research._add_sources(checkpoint, candidates)
    assert len(checkpoint.sources) == research.MAX_SOURCES
    assert all(len(source.content) == research.PER_SOURCE_CHARS for source in checkpoint.sources)
    assert all(len(source.title) == 200 for source in checkpoint.sources)
    assert [source.n for source in checkpoint.sources] == list(range(1, research.MAX_SOURCES + 1))
    task_research._errors(checkpoint, ["e" * 1000] * 30)
    assert len(checkpoint.errors) == 16
    assert all(len(error) == 100 for error in checkpoint.errors)
    task_research.Checkpoint.model_validate(checkpoint.model_dump())


def test_passages_from_one_local_file_share_a_bounded_source():
    checkpoint = task_research.Checkpoint()
    added = task_research._add_sources(checkpoint, [
        {"title": "Notes", "url": "local", "content": "First passage"},
        {"title": "Notes", "url": "local", "content": "Second passage"},
        {"title": "Notes", "url": "local", "content": "First passage"}])
    assert len(added) == 1
    assert len(checkpoint.sources) == 1
    assert checkpoint.sources[0].content == "First passage\n\nSecond passage"


def test_iteration_override_cannot_expand_worker_budget(monkeypatch, research_tools):
    monkeypatch.setenv("RESEARCH_MAX_ITERATIONS", "10000")
    task = {"payload": {"query": "Q", "subquestions": 1}}
    advance(task)
    assert task["checkpoint"]["subquestions"] == ["First?"]


@pytest.mark.parametrize("character", ["\U00010000", "\x00"])
def test_maximum_checkpoint_and_result_fit_serialized_budget(monkeypatch, character):
    from routers.task_store import MAX_EVENT_BYTES, MAX_JSON_BYTES, encode

    sources = [task_research.Source(
        n=i + 1, title=character * 200, url=character * 1024,
        content=character * research.PER_SOURCE_CHARS) for i in range(research.MAX_SOURCES)]
    checkpoint = task_research.Checkpoint(
        phase="synthesize", subquestions=[character * 500] * 5, next_query=5,
        sources=sources, errors=[character * 100] * 16)
    task = {"payload": {"query": character * 5000}, "checkpoint": checkpoint.model_dump()}

    async def synthesize(*args):
        return character * 15996 + " [1]"

    monkeypatch.setattr(research, "_synthesize", synthesize)
    completed = advance(task)
    assert completed.state == "completed"
    assert len(encode(completed.checkpoint).encode("utf-8")) <= MAX_JSON_BYTES
    assert len(encode(completed.result).encode("utf-8")) <= MAX_JSON_BYTES
    progress = task_research._progress(checkpoint, [source.model_dump() for source in sources])
    assert len(encode(progress.data, MAX_EVENT_BYTES).encode("utf-8")) <= MAX_EVENT_BYTES


@pytest.mark.parametrize("reason", ["request_limit", "input_limit", "request_conflict"])
def test_terminal_generation_reason_survives_checkpoint(reason, monkeypatch):
    async def failed(task, payload, checkpoint):
        raise task_research.native_generation.NativeGenerationFailed(reason)

    monkeypatch.setattr(task_research, "_run", failed)
    result = asyncio.run(task_research.step({"payload": {"query": "Fictional question"}}))
    assert result.state == "failed"
    reopened = task_research.Checkpoint.model_validate_json(json.dumps(result.checkpoint))
    assert reopened.failure_reason == reason
    assert not reopened.errors
