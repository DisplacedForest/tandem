import asyncio
import shutil
import uuid
from pathlib import Path

import pytest

from pi_assistant.app_model import AppModelTransport
from pi_assistant.process import PiFailure
from pi_assistant.runtime import Runtime
from test_runtime import body, approve, wait_state

NAME = 'mcp_' + 'a' * 40
SCHEMA = {'name': NAME, 'description': 'Read fixture data', 'parameters': {'type': 'object', 'properties': {'query': {'type': 'string'}}, 'required': ['query'], 'additionalProperties': False}}


class HostFixture(AppModelTransport):
    def __init__(self):
        super().__init__(str(uuid.uuid4()), str(uuid.uuid4()))
        self.frames = []
        self.tool_calls = []
        self.enabled = True
        self.block = False
        self.entered = asyncio.Event()

    async def start(self):
        pass

    def authorize(self, subject, role, mode, assistant, conversation):
        self.scopes[(subject, role)] = {'scope': str(uuid.uuid4()), 'subject': subject, 'role': role, 'mode': mode, 'assistant': assistant, 'conversation': conversation, 'profile': self.profile}
        self.scope_changed.set()

    def send(self, frame):
        self.frames.append(frame)
        if frame['op'] == 'cancel':
            return
        if frame['op'] == 'tool_catalog':
            result = {'tools': [SCHEMA] if self.enabled else []}
        elif frame['op'] == 'tool_call':
            self.entered.set()
            if self.block:
                return
            self.tool_calls.append(frame)
            result = {'value': {'answer': 'fixture value'}}
        else:
            messages = frame['messages']
            prior = sum(len([b for b in message.get('content', []) if isinstance(b, dict) and b.get('type') == 'toolCall']) for message in messages if message['role'] == 'assistant')
            if prior:
                content = [{'type': 'text', 'text': 'Host tools completed'}]
            elif messages[-1].get('content', '').startswith('/task '):
                content = [{'type': 'toolCall', 'id': 'delegate-id', 'name': 'delegate', 'arguments': {'objective': 'fixture'}}]
            else:
                content = [{'type': 'toolCall', 'id': 'host-call-id', 'name': NAME, 'arguments': {'query': 'fixture'}}]
                if frame['role'] == 'worker':
                    content += [{'type': 'toolCall', 'id': name, 'name': name, 'arguments': {'path': 'sum.py', **({'content': 'def add(a, b):\n    return a + b\n'} if name == 'write_file' else {})}} for name in ('read_file', 'write_file', 'check_python')]
            result = {'content': content, 'usage': {'input': 20, 'output': 4, 'cost_usd': 0}}
        self.receive({'op': 'reply', 'id': frame['id'], 'ok': True, 'result': result})


@pytest.mark.asyncio
@pytest.mark.parametrize('mode', ['assistant', 'focused'])
async def test_sdk_calls_scoped_host_tool_foreground(tmp_path, mode):
    transport = HostFixture()
    runtime = Runtime(tmp_path, shutil.which('node'), model_transport=transport)
    await runtime.start()
    request = body('read fixture', mode=mode)
    transport.authorize(request['message_id'], 'foreground', mode, request['assistant_id'], request['conversation_id'])
    try:
        result = await runtime.message(request)
        assert result['text'] == 'Host tools completed'
        assert len(transport.tool_calls) == 1
        call = transport.tool_calls[0]
        assert call['call_id'] == 'host-call-id' and call['mode'] == mode and call['subject'] == request['message_id']
        assert call['arguments'] == {'query': 'fixture'}
        assert result['task_ids'] == []
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_sdk_worker_host_tool_waits_for_task_approval(tmp_path):
    transport = HostFixture()
    runtime = Runtime(tmp_path, shutil.which('node'), model_transport=transport)
    await runtime.start()
    request = body()
    transport.authorize(request['message_id'], 'foreground', 'assistant', request['assistant_id'], request['conversation_id'])
    try:
        accepted = await runtime.message(request)
        task_id = accepted['task_ids'][0]
        await wait_state(runtime, task_id, {'needs_decision'})
        assert transport.tool_calls == []
        transport.authorize(task_id, 'worker', 'assistant', request['assistant_id'], request['conversation_id'])
        await approve(runtime, task_id)
        task = await wait_state(runtime, task_id, {'completed'})
        assert len(transport.tool_calls) == 1 and transport.tool_calls[0]['subject'] == task_id
        assert Path(task['result']['artifacts'][0]['path']).read_text() == 'def add(a, b):\n    return a + b\n'
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_sdk_disabled_catalog_never_invokes_host(tmp_path):
    transport = HostFixture()
    transport.enabled = False
    runtime = Runtime(tmp_path, shutil.which('node'), model_transport=transport)
    await runtime.start()
    request = body('read fixture', mode='focused')
    transport.authorize(request['message_id'], 'foreground', 'focused', request['assistant_id'], request['conversation_id'])
    try:
        await runtime.message(request)
        assert transport.tool_calls == []
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_sdk_worker_cancel_cancels_native_host_request(tmp_path):
    transport = HostFixture()
    transport.block = True
    runtime = Runtime(tmp_path, shutil.which('node'), model_transport=transport)
    await runtime.start()
    request = body()
    transport.authorize(request['message_id'], 'foreground', 'assistant', request['assistant_id'], request['conversation_id'])
    try:
        task_id = (await runtime.message(request))['task_ids'][0]
        transport.authorize(task_id, 'worker', 'assistant', request['assistant_id'], request['conversation_id'])
        await approve(runtime, task_id)
        await asyncio.wait_for(transport.entered.wait(), 3)
        runtime.store.cancel(task_id)
        await wait_state(runtime, task_id, {'canceled'})
        assert any(frame['op'] == 'cancel' for frame in transport.frames)
        assert not runtime.process.pids
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_host_channel_rejects_missing_or_wrong_scope():
    transport = HostFixture()
    subject, assistant, conversation = (str(uuid.uuid4()) for _ in range(3))
    with pytest.raises(PiFailure):
        await transport.tools(subject, 'foreground', 'assistant')
    transport.authorize(subject, 'foreground', 'focused', assistant, conversation)
    with pytest.raises(PiFailure):
        await transport.tools(subject, 'foreground', 'assistant')
    assert transport.frames == []
    transport.close()
