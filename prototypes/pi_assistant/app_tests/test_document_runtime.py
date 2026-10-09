import asyncio
import json
from pathlib import Path
import shutil
import sys
import uuid

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'services/vera-api'))

from pi_assistant.runtime import Runtime
from pi_assistant.process import PiFailure
from pi_assistant.documents import DocumentRequest
from routers.task_store import TaskConflict


class Model:
    kind = 'app-owned-mock'

    def __init__(self):
        self.scopes = set()
        self.calls = []
        self.hold = False
        self.started = asyncio.Event()

    async def start(self):
        pass

    async def stop(self):
        pass

    def validate_scope(self, subject, role, mode, assistant, conversation):
        if role == 'document' and (subject, assistant, conversation) not in self.scopes:
            raise PiFailure('scope')

    async def wait_scope(self, *args):
        self.validate_scope(*args)

    async def complete(self, event, subject, role, mode):
        self.calls.append((subject, role, mode, event))
        self.started.set()
        if self.hold:
            await asyncio.Event().wait()
        prompt = event['context']['messages'][0]['content']
        content = {'sections': [{'heading': 'First', 'instructions': 'Use inputs'}, {'heading': 'Second', 'instructions': 'Use inputs'}]} if 'Plan at most' in prompt else {'text': 'Saved content [1].\n\n## Sources\n\nSupplied notes.'}
        return {'content': [{'type': 'text', 'text': json.dumps(content)}]}


def message(**change):
    return {'assistant_id': str(uuid.uuid4()), 'conversation_id': str(uuid.uuid4()), 'message_id': str(uuid.uuid4()),
            'mode': 'assistant', 'text': 'Create document: Notes', 'document': {'title': 'Notes', 'brief': 'Use supplied notes', 'inputs': ['Explicit notes'], 'max_sections': 2}, **change}


async def wait(runtime, task_id, state):
    for _ in range(200):
        task = runtime.store.get(task_id)
        if task['state'] == state:
            return task
        await asyncio.sleep(.02)
    raise AssertionError(runtime.store.get(task_id))


def test_document_idempotent_creation_origin_and_completion(tmp_path):
    async def scenario():
        model = Model()
        runtime = Runtime(tmp_path, shutil.which('node'), model_transport=model)
        body = message()
        first = await runtime.message(body)
        assert await runtime.message(body) == first
        with pytest.raises(TaskConflict):
            await runtime.message({**body, 'document': {**body['document'], 'brief': 'changed'}})
        task_id = first['task_ids'][0]
        model.scopes.add((task_id, body['assistant_id'], body['conversation_id']))
        await runtime.start()
        try:
            task = await wait(runtime, task_id, 'completed')
            assert len(model.calls) == 5
            assert all(role == 'document' and mode == 'assistant' for _, role, mode, _ in model.calls)
            assert task['payload']['originating_message_id'] == body['message_id']
            assert task['result']['markdown'] == (runtime.workspace / task_id / 'document.md').read_text()
            assert task['result']['display_blocks'][0]['artifact']['report'] == task['result']['markdown']
            assert len(runtime.messages(body['conversation_id'])['messages']) == 2
            assert runtime.messages(str(uuid.uuid4())) == {'messages': []}
            assert len(runtime.store.list()) == 1
        finally:
            await runtime.stop()
    asyncio.run(scenario())


def test_document_recovers_create_before_reply_commit(tmp_path):
    model = Model()
    runtime = Runtime(tmp_path, shutil.which('node'), model_transport=model)
    body = message()
    runtime.accept(body)
    first = runtime.documents.create(body)
    assert runtime.documents.create(body) == first
    assert len(runtime.store.list()) == 1


def test_document_missing_scope_preserves_checkpoint_and_cancel(tmp_path):
    async def scenario():
        model = Model()
        runtime = Runtime(tmp_path, shutil.which('node'), model_transport=model)
        body = message()
        first = await runtime.message(body)
        task_id = first['task_ids'][0]
        await runtime.start()
        try:
            paused = await wait(runtime, task_id, 'needs_decision')
            assert not model.calls and paused['checkpoint']['retry']
            runtime.store.cancel(task_id)
            assert runtime.store.get(task_id)['state'] == 'canceled'
            assert not (runtime.workspace / task_id / 'document.md').exists()
        finally:
            await runtime.stop()
    asyncio.run(scenario())


def test_document_cancel_active_generation(tmp_path):
    async def scenario():
        model = Model()
        model.hold = True
        runtime = Runtime(tmp_path, shutil.which('node'), model_transport=model)
        body = message()
        task_id = (await runtime.message(body))['task_ids'][0]
        model.scopes.add((task_id, body['assistant_id'], body['conversation_id']))
        await runtime.start()
        try:
            await asyncio.wait_for(model.started.wait(), 3)
            runtime.store.cancel(task_id)
            task = await wait(runtime, task_id, 'canceled')
            assert task['result'] is None and len(model.calls) == 1
            assert not (runtime.workspace / task_id / 'document.md').exists()
        finally:
            await runtime.stop()
    asyncio.run(scenario())


@pytest.mark.parametrize('patch', [{'title': 'x\ny'}, {'brief': 'x' * 2001}, {'inputs': ['a', 'b']}, {'max_sections': 5}])
def test_native_document_bounds(patch):
    with pytest.raises(ValueError):
        DocumentRequest.model_validate({**message()['document'], **patch})
