import asyncio
from typing import Any

from . import integrations, model_client, structured, task_document_core as core
from .task_document_core import (
    TOOLS, STEP_TIMEOUT_SECONDS, MAX_TOKENS, DocumentPayload, Checkpoint, Outline,
    Section, SectionText, validate_payload, _limit, _messages,
)
from .task_store import StepResult


async def _generate(payload: DocumentPayload, checkpoint: Checkpoint) -> dict[str, Any] | None:
    messages = _messages(payload, checkpoint)

    def configuration_guard(captured: dict) -> None:
        if not integrations.integration("model") or model_client.config("main") != captured:
            raise model_client.ModelUnavailable("Model integration changed while waiting")

    async def call(fix: str | None) -> str:
        if not integrations.integration("model"):
            raise model_client.ModelUnavailable("Model integration is not enabled")
        text = await model_client.complete_text(
            messages + ([{"role": "user", "content": fix}] if fix else []),
            priority="background", max_tokens=MAX_TOKENS, timeout=STEP_TIMEOUT_SECONDS,
            configuration_guard=configuration_guard)
        if not isinstance(text, str) or len(text.encode("utf-8")) > 65536:
            raise ValueError("Model response exceeds its limit")
        return text

    async with asyncio.timeout(STEP_TIMEOUT_SECONDS):
        result, _ = await structured.parsed(call, Outline if checkpoint.phase == "outline" else SectionText,
                                             repair=min(2, structured._attempts()))
    return result


async def step(task: dict[str, Any]) -> StepResult:
    async def generate(payload, checkpoint):
        try:
            return await _generate(payload, checkpoint)
        except model_client.ModelUnavailable as error:
            raise core.DocumentUnavailable(str(error)) from None
    return await core.step(task, generate)
