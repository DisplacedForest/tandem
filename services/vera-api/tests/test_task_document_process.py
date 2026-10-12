from collections import Counter
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest

from routers.task_store import TaskStore


HELPER = Path(__file__).parent / "fixtures" / "document_worker_process.py"
CALLS = ["outline:0", "draft:1", "draft:2", "revise:1", "revise:2"]


class DocumentProcess:
    def __init__(self, root: Path):
        self.root = root
        self.database = root / "tasks.db"
        self.journal = root / "calls.jsonl"
        self.store = TaskStore(str(self.database))
        self.task = self.store.create("document", {
            "title": "Fixture document", "brief": "Explain the supplied facts.",
            "inputs": ["First fact.", "Second fact."], "max_sections": 2,
        }, "document-request")
        self.processes: list[subprocess.Popen] = []

    def launch(self, block: str = "none") -> tuple[subprocess.Popen, Path]:
        marker = self.root / f"marker-{len(self.processes)}"
        environment = {
            "PATH": os.defpath, "HOME": str(self.root), "CFFIXED_USER_HOME": str(self.root),
            "VERA_CONFIG_DIR": str(self.root / "config"), "INTEGRATIONS_PATH": str(self.root / "integrations.json"),
            "PYTHONDONTWRITEBYTECODE": "1", "LANG": "C.UTF-8",
        }
        process = subprocess.Popen(
            [sys.executable, str(HELPER), str(self.database), str(self.journal), str(marker), block],
            cwd=HELPER.parents[2], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process, marker

    def calls(self) -> list[str]:
        return [json.loads(line) for line in self.journal.read_text().splitlines()] if self.journal.exists() else []

    def snapshot(self) -> dict:
        return self.store.get(self.task["id"])

    def events(self) -> list[dict]:
        return self.store.events(task_id=self.task["id"])

    def finish(self) -> dict:
        process, _ = self.launch()
        output, error = process.communicate(timeout=25)
        assert process.returncode == 0, output + error
        return self.snapshot()

    def close(self) -> None:
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)


@pytest.fixture
def document_process(tmp_path):
    fixture = DocumentProcess(tmp_path)
    try:
        yield fixture
    finally:
        fixture.close()


def wait_ready(process: subprocess.Popen, marker: Path, expected: str) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if marker.exists() and marker.read_text() == expected:
            return
        if process.poll() is not None:
            pytest.fail(f"Document child exited before {expected}: {process.communicate()}")
        time.sleep(0.01)
    pytest.fail(f"Document child did not reach {expected}")


def kill(process: subprocess.Popen) -> None:
    assert process.poll() is None
    process.send_signal(signal.SIGKILL)
    process.communicate(timeout=5)
    assert process.returncode == -signal.SIGKILL


def assert_completed(fixture: DocumentProcess, snapshot: dict) -> None:
    assert snapshot["state"] == "completed"
    result = snapshot["result"]
    assert result["kind"] == "document_report"
    assert result["markdown"] == (
        "# Fixture document\n\n## First section\n\nSaved revise section 1.\n\n"
        "## Second section\n\nSaved revise section 2.\n")
    assert result["display_blocks"][0]["artifact"]["id"] == fixture.task["id"]
    assert result["display_blocks"][0]["artifact"]["report"] == result["markdown"]
    assert sum(event["kind"] == "completed" for event in fixture.events()) == 1


@pytest.mark.parametrize("phase", ["draft", "revise"])
def test_sigkill_uncertain_document_call_waits_for_explicit_retry(document_process, phase):
    fixture = document_process
    blocked = f"{phase}:2"
    child, marker = fixture.launch(blocked)
    wait_ready(child, marker, blocked)
    before = fixture.snapshot()
    checkpoint = before["checkpoint"]
    assert before["state"] == "running"
    assert checkpoint["expected_generation"] == before["generation"]
    assert checkpoint["drafts"] == ["Saved draft section 1."] + (["Saved draft section 2."] if phase == "revise" else [])
    assert checkpoint["revisions"] == (["Saved revise section 1."] if phase == "revise" else [])
    calls = fixture.calls()
    assert calls == CALLS[:CALLS.index(blocked) + 1]
    kill(child)
    for _ in range(2):
        waiting = fixture.finish()
        assert waiting["state"] == "needs_decision"
        assert waiting["result"] is None
        assert waiting["checkpoint"]["drafts"] == checkpoint["drafts"]
        assert waiting["checkpoint"]["revisions"] == checkpoint["revisions"]
        assert waiting["checkpoint"]["retry"] is True
        assert fixture.calls() == calls
    decision = waiting["decision"]["id"]
    fixture.store.respond(fixture.task["id"], decision, "explicit-retry", {"action": "retry"})
    completed = fixture.finish()
    assert_completed(fixture, completed)
    assert Counter(fixture.calls()) == Counter(CALLS + [blocked])
    assert sum(event["kind"] == "recovered" for event in fixture.events()) == 1
    fixture.store.respond(fixture.task["id"], decision, "explicit-retry", {"action": "retry"})
    assert_completed(fixture, fixture.finish())
    assert Counter(fixture.calls()) == Counter(CALLS + [blocked])


@pytest.mark.parametrize("phase", ["draft", "revise"])
@pytest.mark.parametrize("cancel_after_restart", [False, True])
def test_cancel_interrupted_document_keeps_committed_sections(document_process, phase, cancel_after_restart):
    fixture = document_process
    blocked = f"{phase}:2"
    child, marker = fixture.launch(blocked)
    wait_ready(child, marker, blocked)
    checkpoint = fixture.snapshot()["checkpoint"]
    calls = fixture.calls()
    if not cancel_after_restart:
        assert fixture.store.cancel(fixture.task["id"])["cancel_requested"] is True
    kill(child)
    if cancel_after_restart:
        assert fixture.finish()["state"] == "needs_decision"
        assert fixture.calls() == calls
        fixture.store.cancel(fixture.task["id"])
    for _ in range(2):
        canceled = fixture.finish()
        assert canceled["state"] == "canceled"
        assert canceled["result"] is None
        assert canceled["checkpoint"]["drafts"] == checkpoint["drafts"]
        assert canceled["checkpoint"]["revisions"] == checkpoint["revisions"]
        assert fixture.calls() == calls
    assert not any(event["kind"] == "completed" for event in fixture.events())
    assert sum(event["kind"] == "canceled" for event in fixture.events()) == 1


@pytest.mark.parametrize("phase", ["draft", "revise"])
def test_sigkill_after_queued_prepare_runs_unstarted_document_call(document_process, phase):
    fixture = document_process
    blocked = f"prepare:{phase}:2"
    child, marker = fixture.launch(blocked)
    wait_ready(child, marker, blocked)
    before = fixture.snapshot()
    assert before["state"] == "queued"
    assert before["checkpoint"]["expected_generation"] == before["generation"] + 1
    assert fixture.calls() == CALLS[:CALLS.index(f"{phase}:2")]
    kill(child)
    assert_completed(fixture, fixture.finish())
    assert fixture.calls() == CALLS
    assert not any(event["state"] == "needs_decision" for event in fixture.events())
    assert not any(event["kind"] == "recovered" for event in fixture.events())
