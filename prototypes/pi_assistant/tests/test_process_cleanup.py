import signal
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from pi_assistant import process as worker


@pytest.mark.asyncio
async def test_disappearing_darwin_group_is_reaped_before_escalation(monkeypatch):
    operations = []
    def killpg(pid, sig):
        operations.append(sig)
        if len(operations) == 2:
            raise PermissionError()
        if len(operations) == 3:
            raise ProcessLookupError()
    monkeypatch.setattr(worker, 'os', SimpleNamespace(killpg=killpg))
    monkeypatch.setattr(worker, 'sys', SimpleNamespace(platform='darwin'))
    process = SimpleNamespace(pid=43210, wait=AsyncMock())
    await worker.PiProcess('node', Path('agent.mjs')).stop(process)
    assert operations == [signal.SIGTERM, 0, 0]
    process.wait.assert_awaited_once()


@pytest.mark.asyncio
async def test_live_group_escalates_and_reaps(monkeypatch):
    operations = []
    def killpg(pid, sig):
        operations.append(sig)
        if operations[-2:] == [signal.SIGKILL, 0]:
            raise ProcessLookupError()
    clock = iter([0.0, 2.1, 2.2, 2.3])
    monkeypatch.setattr(worker, 'os', SimpleNamespace(killpg=killpg))
    monkeypatch.setattr(worker, 'asyncio', SimpleNamespace(get_running_loop=lambda: SimpleNamespace(time=lambda: next(clock)), sleep=AsyncMock()))
    process = SimpleNamespace(pid=43210, wait=AsyncMock())
    await worker.PiProcess('node', Path('agent.mjs')).stop(process)
    assert operations == [signal.SIGTERM, signal.SIGKILL, 0]
    process.wait.assert_awaited_once()


@pytest.mark.asyncio
async def test_persistent_darwin_denial_preserves_failure(monkeypatch):
    operations = []
    def killpg(pid, sig):
        operations.append(sig)
        if sig == 0:
            raise PermissionError()
    clock = iter([0.0, .1, 2.1])
    monkeypatch.setattr(worker, 'os', SimpleNamespace(killpg=killpg))
    monkeypatch.setattr(worker, 'sys', SimpleNamespace(platform='darwin'))
    monkeypatch.setattr(worker, 'asyncio', SimpleNamespace(get_running_loop=lambda: SimpleNamespace(time=lambda: next(clock)), sleep=AsyncMock()))
    process = SimpleNamespace(pid=43210, wait=AsyncMock())
    with pytest.raises(PermissionError, match='status remained unavailable'):
        await worker.PiProcess('node', Path('agent.mjs')).stop(process)
    assert operations == [signal.SIGTERM, 0]
    process.wait.assert_not_awaited()


@pytest.mark.asyncio
async def test_signal_denial_is_not_ignored(monkeypatch):
    def killpg(pid, sig):
        raise PermissionError()
    monkeypatch.setattr(worker, 'os', SimpleNamespace(killpg=killpg))
    process = SimpleNamespace(pid=43210, wait=AsyncMock())
    with pytest.raises(PermissionError):
        await worker.PiProcess('node', Path('agent.mjs')).stop(process)
    process.wait.assert_not_awaited()
