import asyncio

from routers import research


def test_plan_repairs_invalid_model_json(monkeypatch):
    calls = []

    async def model(messages, **kwargs):
        calls.append(messages)
        return '["old response"]' if len(calls) == 1 else '{"subquestions": ["First?", "Second?"]}'

    monkeypatch.setattr(research, "_vera", model)
    monkeypatch.setenv("STRUCTURED_REPAIR_ATTEMPTS", "1")
    errors = []
    assert asyncio.run(research._plan("Question", 1, errors)) == ["First?"]
    assert len(calls) == 2
    assert "valid JSON object" in calls[1][-1]["content"]
    assert errors


def test_plan_degrades_to_original_query(monkeypatch):
    async def model(messages, **kwargs):
        return '{"subquestions": [7]}'

    monkeypatch.setattr(research, "_vera", model)
    monkeypatch.setenv("STRUCTURED_REPAIR_ATTEMPTS", "0")
    errors = []
    assert asyncio.run(research._plan("Question", 4, errors)) == ["Question"]
    assert errors


def test_blocking_research_keeps_response_contract(monkeypatch):
    async def model(messages, **kwargs):
        if messages[0]["content"] == research.PLAN_SYS:
            return '{"subquestions": ["Question"]}'
        return "Finding [1]."

    async def search(request):
        from routers.websearch import SearchResponse, SearchResult
        return SearchResponse(query=request.query, results=[SearchResult(
            title="Evidence", url="https://example.test/evidence", content="Finding", rendered=False)])

    monkeypatch.setattr(research, "_vera", model)
    monkeypatch.setattr(research, "web_search", search)
    async def flow():
        req = research.ResearchRequest(query="Question", use_rag=False)
        errors: list[str] = []
        subqs = await research._plan(req.query, research._iteration_cap(req.subquestions), errors)
        sources: list[dict] = []
        for sq in subqs:
            await research._search_one(sq, req.pages_per_q, set(), sources, errors)
        for i, s in enumerate(sources, 1):
            s["n"] = i
        report = await research._synthesize(req, subqs, sources, errors)
        return {"ok": True, "query": req.query, "subquestions": subqs, "report": report,
                "sources": [{"n": s["n"], "title": s["title"], "url": s["url"]} for s in sources],
                "errors": errors}

    out = asyncio.run(flow())
    assert out == {"ok": True, "query": "Question", "subquestions": ["Question"],
                   "report": "Finding [1].", "sources": [{"n": 1, "title": "Evidence",
                   "url": "https://example.test/evidence"}], "errors": []}
