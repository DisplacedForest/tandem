import asyncio
import json
import os
import uuid
from typing import Any, Annotated, Literal

from pydantic import Field, StringConstraints

from routers import structured, task_document_core as task_document
from routers.task_store import StepResult, TaskConflict
from .process import PiFailure


class DocumentRequest(task_document.DocumentPayload):
    brief: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2000)]
    inputs: list[Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2000)]] = Field(default_factory=list, max_length=1)
    max_sections: int = Field(default=4, ge=1, le=4)


class NativeDocumentPayload(DocumentRequest):
    assistant_id: str
    conversation_id: str
    originating_message_id: str
    transport: Literal['app-owned-mock', 'app-owned-provider-fixture', 'app-owned-openrouter']


class DocumentWorkflow:
    def __init__(self, runtime):
        self.runtime = runtime

    def create(self, body: dict[str, Any]) -> dict[str, Any]:
        runtime = self.runtime
        if body['mode'] != 'assistant' or runtime.model_transport is None:
            raise TaskConflict('Document creation requires the shared native assistant')
        document = DocumentRequest.model_validate(body['document'])
        runtime.native.validate_scope(body['message_id'], 'foreground', 'assistant', body['assistant_id'], body['conversation_id'])
        previous = runtime.accept(body, resume=True)
        if previous:
            return previous
        payload = NativeDocumentPayload(**document.model_dump(), assistant_id=body['assistant_id'],
            conversation_id=body['conversation_id'], originating_message_id=body['message_id'], transport=runtime.transport)
        task = runtime.store.create('document', payload.model_dump(), 'document:' + body['message_id'])
        answer = {'message_id': body['message_id'], 'reply_id': str(uuid.uuid5(uuid.NAMESPACE_URL, body['message_id'])),
                  'text': 'Your document request is saved. Progress and the document appear on its card.', 'task_ids': [task['id']]}
        with runtime.connect() as db:
            import time
            db.execute("UPDATE turns SET state='completed',answer=?,answered=? WHERE id=?", (json.dumps(answer), time.time(), body['message_id']))
        return answer

    async def step(self, task: dict[str, Any]) -> StepResult:
        runtime = self.runtime
        payload = NativeDocumentPayload.model_validate(task['payload'])
        document = DocumentRequest.model_validate(payload.model_dump(include=set(DocumentRequest.model_fields)))
        checkpoint = task_document.Checkpoint.model_validate(task.get('checkpoint') or {})
        if payload.transport != runtime.transport or runtime.model_transport is None:
            return task_document._pause(document, checkpoint, 'Reconnect the original assistant to continue writing.')
        if task.get('decision_reply') == {'approved': False}:
            runtime.store.cancel(task['id'])
            return StepResult(checkpoint=checkpoint.model_dump(), event='canceled')
        if checkpoint.phase != 'assemble':
            try:
                await runtime.native.wait_scope(task['id'], 'document', 'assistant', payload.assistant_id, payload.conversation_id)
            except PiFailure:
                return task_document._pause(document, checkpoint, 'The assistant restarted. Resume writing from the saved section?')
        async def generate(value, saved):
            messages = task_document._messages(value, saved)
            async def call(fix):
                if runtime.canceled(task):
                    raise asyncio.CancelledError()
                operation = asyncio.create_task(runtime.native.complete({'type': 'model', 'id': str(uuid.uuid4()),
                    'context': {'messages': messages}}, task['id'], 'document', 'assistant'))
                try:
                    while not operation.done():
                        if runtime.canceled(task):
                            raise asyncio.CancelledError()
                        await asyncio.wait({operation}, timeout=.05)
                    reply = await operation
                    if runtime.canceled(task):
                        raise asyncio.CancelledError()
                finally:
                    if not operation.done():
                        operation.cancel()
                    await asyncio.gather(operation, return_exceptions=True)
                content = reply.get('content')
                if not isinstance(content, list) or any(item.get('type') != 'text' for item in content):
                    raise ValueError('Document generation must return text')
                text = ''.join(item['text'] for item in content)
                if len(text.encode()) > 32768:
                    raise ValueError('Document response exceeds its limit')
                return text
            async with asyncio.timeout(30):
                result, _ = await structured.parsed(call, task_document.Outline if saved.phase == 'outline' else task_document.SectionText, repair=0)
            return result
        supplied = {**task, 'payload': document.model_dump()}
        if task.get('decision_reply') == {'approved': True}:
            supplied['decision_reply'] = {'action': 'retry'}
        result = await task_document.step(supplied, generate)
        if result.state == 'completed':
            if runtime.canceled(task):
                raise asyncio.CancelledError()
            self.write(task['id'], result.result['markdown'])
            result.result['summary'] = result.result['spoken_text']
            result.result['artifacts'] = [{'kind': 'file', 'path': str(runtime.workspace / task['id'] / 'document.md'), 'title': document.title}]
        return result

    def write(self, task_id: str, markdown: str) -> None:
        runtime = self.runtime
        try:
            os.mkdir(task_id, 0o700, dir_fd=runtime.workspace_fd)
        except FileExistsError:
            pass
        directory = os.open(task_id, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=runtime.workspace_fd)
        temporary = 'document.' + uuid.uuid4().hex
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            with os.fdopen(descriptor, 'w') as file:
                file.write(markdown)
                file.flush()
                os.fsync(file.fileno())
            os.rename(temporary, 'document.md', src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
            os.close(directory)
