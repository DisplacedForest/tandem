import importlib.util
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest


def load_contract() -> ModuleType:
    path = Path(__file__).resolve().parents[3] / 'scripts' / 'tests' / 'task_engine_contract.py'
    spec = importlib.util.spec_from_file_location('task_engine_contract', path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_source_task_engine_http_crash_replay_contract() -> None:
    module = load_contract()
    report = module.run_contract()
    assert report['transport'] == 'source'
    assert report['events_replayed'] > 200
    assert report['model_requests'] == 0


@pytest.mark.parametrize('status,task', [(404, None), (200, {'id': 'other', 'state': 'queued'}),
                                      (200, {'id': 'fixture', 'state': 'running'})])
def test_readiness_refuses_an_unrelated_listener(status: int, task: dict | None) -> None:
    module = load_contract()
    engine = object.__new__(module.Engine)
    engine.process = SimpleNamespace(poll=lambda: None)
    engine.identity = {'id': 'fixture', 'state': 'queued'}
    requests: list[tuple[str, str]] = []

    def request(method: str, path: str) -> tuple[int, dict | None]:
        requests.append((method, path))
        return (200, {}) if path == '/version' else (status, task)

    engine.request = request
    assert not engine.available()
    assert requests == [('GET', '/version'), ('GET', '/tasks/fixture')]
