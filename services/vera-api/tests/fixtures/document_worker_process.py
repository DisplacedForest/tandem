import asyncio
import json
import os
from pathlib import Path
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from routers import task_document
from routers.task_runtime import Dispatcher
from routers.task_store import TaskStore


def write_ready(marker: Path, label: str) -> None:
    with marker.open("w", encoding="utf-8") as handle:
        handle.write(label)
        handle.flush()
        os.fsync(handle.fileno())


async def run(database: str, journal: str, marker: str, block: str) -> None:
    store = TaskStore(database)
    ready = Path(marker)

    async def model(messages, **options):
        context = json.loads(messages[1]["content"])
        phase = "outline" if "section" not in context else "revise" if "draft" in context else "draft"
        section = context.get("section", 0)
        label = f"{phase}:{section}"
        assert options["priority"] == "background"
        with open(journal, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(label) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        if block == label:
            write_ready(ready, label)
            await asyncio.Event().wait()
        if phase == "outline":
            return json.dumps({"sections": [
                {"heading": "First section", "instructions": "Describe the supplied first fact."},
                {"heading": "Second section", "instructions": "Describe the supplied second fact."},
            ]})
        return json.dumps({"text": f"Saved {phase} section {section}."})

    task_document.model_client.complete_text = model
    task_document.integrations.integration = lambda name: {"model": "fixture"} if name == "model" else None
    commit = store.commit_step

    def commit_step(task_id, generation, result):
        saved = commit(task_id, generation, result)
        checkpoint = saved["checkpoint"]
        phase = checkpoint.get("phase")
        section = len(checkpoint.get("drafts" if phase == "draft" else "revisions", [])) + 1
        label = f"prepare:{phase}:{section}"
        if block == label and saved["state"] == "queued" and checkpoint.get("expected_generation") is not None:
            write_ready(ready, label)
            threading.Event().wait()
        return saved

    store.commit_step = commit_step
    dispatcher = Dispatcher(store, poll_seconds=0.01)
    dispatcher.register("document", task_document.step, 35, task_document.TOOLS)
    await dispatcher.start()
    try:
        async with asyncio.timeout(20):
            while store.list()[0]["state"] not in {"completed", "canceled", "failed", "needs_decision"}:
                await asyncio.sleep(0.01)
    finally:
        await dispatcher.stop()


if __name__ == "__main__":
    asyncio.run(run(*sys.argv[1:]))
