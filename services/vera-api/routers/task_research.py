import re
import uuid
from typing import Annotated, Any, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from . import native_generation, research
from .task_store import StepResult


ShortText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
TOOLS = ("model", "web_search", "local_knowledge")


class ResearchPayload(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    query: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=5000)]
    deliverables: list[ShortText] = Field(default_factory=list, max_length=5)
    native_binding: native_generation.NativeBinding | None = None
    subquestions: int = Field(default=4, ge=1, le=5)
    pages_per_q: int = Field(default=2, ge=0, le=4)
    use_rag: bool = True


def validate_payload(payload: dict[str, Any]) -> None:
    ResearchPayload.model_validate(payload)


class Source(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    n: int = Field(ge=1, le=research.MAX_SOURCES)
    title: str = Field(max_length=200)
    url: str = Field(min_length=1, max_length=1024)
    content: str = Field(min_length=1, max_length=research.PER_SOURCE_CHARS)


class Checkpoint(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    phase: Literal["plan", "gather", "rag", "synthesize"] = "plan"
    subquestions: list[ShortText] = Field(default_factory=list, max_length=5)
    next_query: int = Field(default=0, ge=0, le=5)
    sources: list[Source] = Field(default_factory=list, max_length=research.MAX_SOURCES)
    errors: list[Annotated[str, StringConstraints(max_length=100)]] = Field(default_factory=list, max_length=16)
    retry: bool = False
    attempt: Annotated[str, StringConstraints(pattern=r"^[a-zA-Z0-9-]{1,70}$")] = "initial"
    native_unavailable: str | None = Field(default=None, max_length=80)
    failure_reason: Literal["request_limit", "input_limit", "request_conflict"] | None = None


def _text(value: Any, limit: int) -> str:
    return str(value).encode("utf-8", errors="replace").decode("utf-8").strip()[:limit]


def _errors(checkpoint: Checkpoint, errors: list[str]) -> None:
    checkpoint.errors = (checkpoint.errors + [_text(error, 100) for error in errors])[-16:]


def _add_sources(checkpoint: Checkpoint, candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen = {(s.url, s.title if s.url == "local" else ""): s for s in checkpoint.sources}
    added = []
    for candidate in candidates:
        url = str(candidate.get("url", "")).strip()
        title = _text(candidate.get("title", ""), 200)
        content = _text(candidate.get("content", ""), research.PER_SOURCE_CHARS)
        try:
            url.encode("utf-8")
            valid_url = url == "local" or (urlsplit(url).scheme in {"http", "https"} and bool(urlsplit(url).hostname))
        except ValueError:
            valid_url = False
        key = (url, title if url == "local" else "")
        if not content or not valid_url or len(url) > 1024:
            continue
        if key in seen:
            if url == "local" and content not in seen[key].content:
                seen[key].content = (seen[key].content + "\n\n" + content)[:research.PER_SOURCE_CHARS]
            continue
        if len(checkpoint.sources) >= research.MAX_SOURCES:
            continue
        source = Source(n=len(checkpoint.sources) + 1, title=title, url=url, content=content)
        checkpoint.sources.append(source)
        seen[key] = source
        added.append(source.model_dump(exclude={"content"}))
    return added


def _pause(checkpoint: Checkpoint, reason: str) -> StepResult:
    _errors(checkpoint, [reason])
    checkpoint.retry = True
    checkpoint.attempt = uuid.uuid4().hex
    return StepResult(
        state="needs_decision", checkpoint=checkpoint.model_dump(), event="progress",
        data={"message": reason}, decision={"prompt": reason + " Retry this step?", "choices": ["retry"]})


def _progress(checkpoint: Checkpoint, added: list[dict[str, Any]] | None = None) -> StepResult:
    return StepResult(
        checkpoint=checkpoint.model_dump(), event="source_found" if added else "progress",
        data={"phase": checkpoint.phase, "queries_completed": checkpoint.next_query,
              "sources_count": len(checkpoint.sources),
              "sources": [{"n": source["n"], "title": source["title"][:200]}
                          for source in (added or [])[:6]]})


async def step(task: dict[str, Any]) -> StepResult:
    payload = ResearchPayload.model_validate(task["payload"])
    checkpoint = Checkpoint.model_validate(task.get("checkpoint") or {})
    try:
        return await _run(task, payload, checkpoint)
    except native_generation.NativeExecutorUnavailable:
        checkpoint.native_unavailable = payload.native_binding.id if payload.native_binding else None
        return StepResult(state="blocked", checkpoint=checkpoint.model_dump(), event="progress",
                          data={"message": "Open Vera with the original model profile to continue this research."})
    except native_generation.NativeGenerationFailed as error:
        if error.reason in {"request_limit", "request_conflict", "input_limit"}:
            checkpoint.failure_reason = error.reason
            return StepResult(state="failed", checkpoint=checkpoint.model_dump(), event="failed",
                data={"message": "This research task reached its saved generation limit." if error.reason == "request_limit"
                      else "This research input exceeds the task's saved input limit." if error.reason == "input_limit"
                      else "The saved model request conflicts with an earlier attempt."})
        messages = {"provider_auth": "The saved model credential was not accepted.",
                    "provider_quota": "The model provider's usage limit was reached.",
                    "credential_unavailable": "The saved model credential is unavailable.",
                    "previous_request_uncertain": "The previous model request ended without a saved response."}
        return _pause(checkpoint, messages.get(error.reason, "The model request did not complete."))


async def _run(task: dict[str, Any], payload: ResearchPayload, checkpoint: Checkpoint) -> StepResult:
    checkpoint.native_unavailable = None
    request = research.ResearchRequest(**payload.model_dump(exclude={"native_binding"}))
    call = native_generation.caller(task, checkpoint.phase, checkpoint.attempt) if payload.native_binding else None
    errors: list[str] = []
    if checkpoint.retry:
        if task.get("decision_reply") != {"action": "retry"}:
            return _pause(checkpoint, "Research needs an explicit retry to continue.")
        checkpoint.retry = False

    if checkpoint.phase == "plan":
        cap = min(5, payload.subquestions, max(1, research._iteration_cap(payload.subquestions)))
        if call is None:
            questions = await research._plan(payload.query, cap, errors)
        else:
            questions = await research._plan(payload.query, cap, errors, call=call)
        checkpoint.subquestions = [_text(question, 500) for question in questions[:cap] if question.strip()]
        if not checkpoint.subquestions:
            checkpoint.subquestions = [payload.query[:500]]
        checkpoint.phase = "gather"
        _errors(checkpoint, errors)
        return _progress(checkpoint)

    if checkpoint.phase == "gather":
        if checkpoint.next_query >= len(checkpoint.subquestions):
            checkpoint.phase = "rag" if payload.use_rag else "synthesize"
            return _progress(checkpoint)
        candidates: list[dict[str, Any]] = []
        await research._search_one(checkpoint.subquestions[checkpoint.next_query], payload.pages_per_q,
                                   set(), candidates, errors)
        added = _add_sources(checkpoint, candidates)
        _errors(checkpoint, errors)
        checkpoint.next_query += 1
        if checkpoint.next_query == len(checkpoint.subquestions):
            checkpoint.phase = "rag" if payload.use_rag else "synthesize"
        return _progress(checkpoint, added)

    if checkpoint.phase == "rag":
        added = _add_sources(checkpoint, await research._rag_sources(payload.query, errors))
        _errors(checkpoint, errors)
        checkpoint.phase = "synthesize"
        return _progress(checkpoint, added)

    if not checkpoint.sources:
        checkpoint.phase = "gather"
        checkpoint.next_query = 0
        return _pause(checkpoint, "No usable sources were gathered.")
    sources = [source.model_dump() for source in checkpoint.sources]
    if call is None:
        report = await research._synthesize(request, checkpoint.subquestions, sources, errors)
    else:
        report = await research._synthesize(request, checkpoint.subquestions, sources, errors, call=call)
    _errors(checkpoint, errors)
    try:
        report.encode("utf-8")
    except UnicodeError:
        return _pause(checkpoint, "Research did not produce a usable report.")
    if not report or len(report) > 16000:
        return _pause(checkpoint, "Research did not produce a usable report.")
    references = {number.lstrip("0") or "0" for number in re.findall(r"\[([0-9]+)\]", report)}
    if not references or not references.issubset({str(source.n) for source in checkpoint.sources}):
        return _pause(checkpoint, "The report did not cite the gathered sources correctly.")
    result = {"kind": "research_report", "query": payload.query, "report": report,
              "subquestions": checkpoint.subquestions,
              "sources": [source.model_dump(exclude={"content"}) for source in checkpoint.sources],
              "errors": checkpoint.errors}
    return StepResult(state="completed", checkpoint=checkpoint.model_dump(), result=result,
                      event="completed", data={"sources_count": len(checkpoint.sources)})
