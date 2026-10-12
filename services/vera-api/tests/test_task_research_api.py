import asyncio

from fastapi import FastAPI
import httpx

from routers import task_research, tasks
from routers.task_runtime import Dispatcher
from routers.task_store import TaskStore


def test_research_payload_validation_and_duplicate_replay(tmp_path, monkeypatch):
    store = TaskStore(str(tmp_path / "tasks.db"))
    monkeypatch.setattr(tasks, "_runtime", None)
    monkeypatch.setattr(tasks, "_workers", {})
    monkeypatch.setattr(tasks, "_validators", {})
    tasks.register_worker("research", task_research.step, 180, task_research.TOOLS,
                          task_research.validate_payload)
    engine = Dispatcher(store)
    worker = tasks._workers["research"]
    engine.register("research", worker.step, worker.timeout_seconds, worker.tools)
    monkeypatch.setattr(tasks, "_runtime", engine)

    async def run():
        app = FastAPI()
        app.include_router(tasks.router)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            body = {"worker_type": "research", "payload": {"query": "Question"}, "idempotency_key": "request"}
            invalid = await client.post("/tasks", json={**body, "payload": {"query": " "}})
            assert invalid.status_code == 422
            assert store.list() == []
            assert store.events() == []
            created = await client.post("/tasks", json=body)
            assert created.status_code == 201
            assert created.json()["payload"] == {"query": "Question"}
            assert (await client.get("/tasks")).json()["available_workers"] == ["research"]

            def reject(payload):
                raise ValueError("Schema changed")

            tasks._validators["research"] = reject
            replay = await client.post("/tasks", json=body)
            assert replay.status_code == 201
            assert replay.json()["id"] == created.json()["id"]
            conflict = await client.post("/tasks", json={**body, "payload": {"query": " "}})
            assert conflict.status_code == 409
            rejected = await client.post("/tasks", json={**body, "idempotency_key": "new"})
            assert rejected.status_code == 422
            assert len(store.list()) == 1
            assert len(store.events()) == 1

    asyncio.run(run())


def test_validator_cannot_rewrite_stored_payload(tmp_path):
    store = TaskStore(str(tmp_path / "tasks.db"))
    payload = {"query": "Original"}

    def mutate(candidate):
        candidate["query"] = "Changed"

    created = store.create("research", payload, "request", mutate)
    assert payload == {"query": "Original"}
    assert created["payload"] == payload
    assert store.create("research", payload, "request")["id"] == created["id"]


def test_main_registers_research_with_tools_and_validator(tmp_path):
    import os
    from pathlib import Path
    import subprocess
    import sys

    env = os.environ.copy()
    env["VERA_DATA_DIR"] = str(tmp_path)
    result = subprocess.run(
        [sys.executable, "-c", "import main; from routers import tasks, task_research; "
         "worker = tasks._workers['research']; assert worker.step is task_research.step; "
         "assert worker.tools == task_research.TOOLS; "
         "assert tasks._validators['research'] is task_research.validate_payload"],
        cwd=Path(__file__).resolve().parents[1], env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
