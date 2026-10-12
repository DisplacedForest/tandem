import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

from routers.task_store import TaskStore


CHILD = r'''
import asyncio
import json
from pathlib import Path
import sys

from routers import research, task_research
from routers.task_runtime import Dispatcher
from routers.task_store import TaskStore
from routers.websearch import SearchResponse, SearchResult

db, journal, marker, block = sys.argv[1:]
store = TaskStore(db)

def record(name):
    with open(journal, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(name) + "\n")

async def pause(name):
    if block == name:
        Path(marker).write_text(name)
        await asyncio.Event().wait()

async def model(messages, **kwargs):
    if messages[0]["content"] == research.PLAN_SYS:
        record("plan")
        return '{"subquestions":["First?","Second?"]}'
    record("synthesis")
    await pause("synthesis")
    return "Findings from both sources [1] [2]."

async def search(request):
    record(request.query)
    if request.query == "Second?":
        await pause("gather")
    return SearchResponse(query=request.query, results=[SearchResult(
        title=request.query, url="https://example.test/" + request.query[:-1],
        content="Evidence for " + request.query, rendered=False)])

research._vera = model
research.web_search = search

async def run():
    dispatcher = Dispatcher(store, poll_seconds=0.01)
    dispatcher.register("research", task_research.step, timeout_seconds=20)
    await dispatcher.start()
    try:
        while store.list()[0]["state"] not in {"completed", "canceled", "failed", "needs_decision"}:
            await asyncio.sleep(0.01)
    finally:
        await dispatcher.stop()

asyncio.run(run())
'''


def launch(db, journal, marker, block):
    return subprocess.Popen(
        [sys.executable, "-c", CHILD, str(db), str(journal), str(marker), block],
        cwd=Path(__file__).resolve().parents[1], env=os.environ.copy(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def await_marker(process, marker):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if marker.exists():
            return
        if process.poll() is not None:
            pytest.fail(f"Child exited before checkpoint: {process.communicate()}")
        time.sleep(0.01)
    pytest.fail("Child did not reach its blocked step")


def stop(process):
    if process.poll() is None:
        process.kill()
    process.communicate(timeout=5)


@pytest.mark.parametrize("phase", ["gather", "synthesis"])
def test_process_kill_resumes_research_from_last_checkpoint(tmp_path, phase):
    db, journal, marker = [tmp_path / name for name in ("tasks.db", "calls.jsonl", "blocked")]
    store = TaskStore(str(db))
    task = store.create("research", {"query": "Question", "use_rag": False}, "request")
    child = launch(db, journal, marker, phase)
    try:
        await_marker(child, marker)
        checkpoint = store.get(task["id"])["checkpoint"]
        assert len(checkpoint["sources"]) == (1 if phase == "gather" else 2)
        assert checkpoint["phase"] == ("gather" if phase == "gather" else "synthesize")
    finally:
        stop(child)
    restarted = launch(db, journal, marker, "none")
    try:
        stdout, stderr = restarted.communicate(timeout=15)
        assert restarted.returncode == 0, stdout + stderr
    finally:
        stop(restarted)
    completed = store.get(task["id"])
    assert completed["state"] == "completed"
    assert completed["result"]["report"] == "Findings from both sources [1] [2]."
    calls = [json.loads(line) for line in journal.read_text().splitlines()]
    assert calls.count("plan") == 1
    assert calls.count("First?") == 1
    assert calls.count("Second?") == (2 if phase == "gather" else 1)
    assert calls.count("synthesis") == (1 if phase == "gather" else 2)
    events = store.events(task_id=task["id"])
    assert sum(event["kind"] == "source_found" for event in events) == 2
    assert sum(event["kind"] == "completed" for event in events) == 1
    assert any(event["kind"] == "recovered" for event in events)


def test_cancel_during_gather_survives_restart_with_partial_evidence(tmp_path):
    db, journal, marker = [tmp_path / name for name in ("tasks.db", "calls.jsonl", "blocked")]
    store = TaskStore(str(db))
    task = store.create("research", {"query": "Question", "use_rag": False}, "request")
    child = launch(db, journal, marker, "gather")
    try:
        await_marker(child, marker)
        store.cancel(task["id"])
    finally:
        stop(child)
    restarted = launch(db, journal, marker, "none")
    try:
        stdout, stderr = restarted.communicate(timeout=15)
        assert restarted.returncode == 0, stdout + stderr
    finally:
        stop(restarted)
    canceled = store.get(task["id"])
    assert canceled["state"] == "canceled"
    assert canceled["result"] is None
    assert len(canceled["checkpoint"]["sources"]) == 1
    calls = [json.loads(line) for line in journal.read_text().splitlines()]
    assert calls == ["plan", "First?", "Second?"]
    assert not any(event["kind"] == "completed" for event in store.events(task_id=task["id"]))
