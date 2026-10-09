import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys

import httpx
from fastapi import FastAPI

from routers import task_document, tasks
from routers.task_runtime import Dispatcher
from routers.task_store import TaskStore


def test_registered_document_worker():
    import main
    worker = main.tasks._workers['document']
    assert worker.step is task_document.step
    assert worker.tools == ('model',)
    assert worker.timeout_seconds > task_document.STEP_TIMEOUT_SECONDS
    assert main.tasks._validators['document'] is task_document.validate_payload


def test_actual_document_api_result_and_native_consumer(tmp_path, monkeypatch):
    calls = []
    markdown = 'Keep literal [1] and [2].\n\n## Sources\n\nThese are document notes.\n\n```text\n[3] is literal\n```\n\n[Unsafe](file:///private/fixture)\n\n![Remote image](https://image.invalid/pixel.png)'

    async def model(messages, **kwargs):
        context = json.loads(messages[1]['content'])
        calls.append((context, kwargs))
        assert kwargs['priority'] == 'background'
        if 'section' not in context:
            return json.dumps({'sections': [{'heading': 'Plan', 'instructions': 'Preserve the supplied notes.'}]})
        return json.dumps({'text': markdown})

    monkeypatch.setattr(task_document.integrations, 'integration', lambda name: {'url': 'https://model.invalid/v1', 'model': 'fixture'} if name == 'model' else None)
    monkeypatch.setattr(task_document.model_client, 'complete_text', model)

    async def exercise():
        store = TaskStore(str(tmp_path / 'tasks.db'))
        engine = Dispatcher(store, poll_seconds=0.002)
        engine.register('document', task_document.step, task_document.STEP_TIMEOUT_SECONDS + 5, task_document.TOOLS)
        monkeypatch.setattr(tasks, '_runtime', engine)
        monkeypatch.setitem(tasks._validators, 'document', task_document.validate_payload)
        app = FastAPI()
        app.include_router(tasks.router)
        await engine.start()
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://engine.test') as client:
                request = {'worker_type': 'document', 'idempotency_key': 'document-acceptance', 'payload': {'title': 'Working plan', 'brief': 'Write from these supplied notes.', 'inputs': [markdown], 'max_sections': 1}}
                bad = await client.post('/tasks', json={**request, 'idempotency_key': 'invalid', 'payload': {**request['payload'], 'native_binding': {'id': 'forbidden'}}})
                assert bad.status_code == 422
                assert calls == []
                created = await client.post('/tasks', json=request)
                assert created.status_code == 201
                task_id = created.json()['id']
                replay = await client.post('/tasks', json=request)
                assert replay.status_code == 201 and replay.json()['id'] == task_id
                for _ in range(500):
                    response = await client.get('/tasks/' + task_id)
                    snapshot = response.json()
                    if snapshot['state'] in {'completed', 'failed', 'needs_decision'}:
                        break
                    await asyncio.sleep(0.005)
                assert snapshot['state'] == 'completed', snapshot['state']
                assert len(calls) == 3
                assert snapshot['result']['markdown'] == '# Working plan\n\n## Plan\n\n' + markdown + '\n'
                artifact = snapshot['result']['display_blocks'][0]
                assert artifact == {'type': 'artifact', 'artifact': {'id': task_id, 'title': 'Working plan', 'report': snapshot['result']['markdown'], 'sources': []}}
                assert snapshot['result']['spoken_text'] == 'The document is ready.'
                assert markdown not in snapshot['result']['spoken_text']
                assert len((await client.get('/tasks')).json()['tasks']) == 1
                assert sum(event['kind'] == 'completed' for event in store.events(task_id=task_id)) == 1
                assert TaskStore(store.path).get(task_id)['result'] == snapshot['result']
                return snapshot
        finally:
            assert await engine.stop()

    snapshot = asyncio.run(exercise())
    output = tmp_path / 'completed-document.json'
    output.write_text(json.dumps(snapshot))
    native = os.environ.get('VERA_NATIVE_DOCUMENT_TEST') == '1'
    consumer = None
    if native:
        assert sys.platform == 'darwin'
        repo = Path(__file__).resolve().parents[3]
        binary = repo / 'apps/vera-mac/.build/debug/Vera'
        result = subprocess.run([str(binary), '--document-artifact-selftest', '--snapshot', str(output)], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        consumer = json.loads(result.stdout)
        assert consumer['api_snapshot'] is True
        assert consumer['artifact_id'] == snapshot['id'] and consumer['artifact_count'] == 1
        assert consumer['content_preserved'] and consumer['typed_roundtrip'] and consumer['speech_uses_spoken_text_only']
        assert consumer['automatic_task_discovery'] is False and consumer['visible_launch'] is False
    evidence = os.environ.get('VERA_DOCUMENT_TEST_EVIDENCE')
    if evidence:
        destination = Path(evidence)
        destination.mkdir(parents=True, exist_ok=True)
        (destination / 'completed-document.json').write_text(json.dumps(snapshot, indent=2) + '\n')
        (destination / 'consumer-result.json').write_text(json.dumps({'native_consumer': consumer, 'task_id': snapshot['id'], 'model_calls': len(calls), 'provider_calls': 0, 'task_count': 1, 'artifact_id': snapshot['result']['display_blocks'][0]['artifact']['id']}, indent=2) + '\n')
