# Tandem DSH runtime

This package runs Tandem's background task loop using the pinned DeepSeek Harness SDK. It supplies DSH with host-owned model completions and host-owned tools. It does not load DSH's CLI, filesystem tools, shell tools, provider credentials, user plugins, or package installation features.

Node 24.22.3 or newer is required. Install dependencies with `npm ci --ignore-scripts`, run checks with `npm test`, and start the process with `node sidecar.mjs`. Tandem's application package includes its own Node runtime and dependencies.

## Responsibility boundaries

DSH owns agent turns, message history, tool-call interpretation, and history compaction. Tandem owns model selection and inference settings, model admission, tool schemas, permission decisions, effect execution, receipts, task scheduling, cancellation, and durable checkpoints. Every model request passes through Tandem. Every tool batch returns to Tandem before any effect occurs.

The integration uses public DSH plugins and extension APIs. `runtime.mjs` registers a model adapter and a tool executor. The executor checkpoints the full batch and yields. It never invokes the registered tool implementations. Only the supplied tool schemas are advertised, in the supplied order.

## Process protocol

Input and output use one JSON object per line over standard input and standard output. Each frame is limited to 16 MiB. The process handles one start request and exits after a boundary, a final answer, or an error. Standard output is reserved for protocol messages.

A start request contains:

```json
{
  "type": "start",
  "systemPrompt": "Trusted task instructions",
  "prompt": "The assignment",
  "tools": [{ "name": "lookup", "description": "Look up a record", "parameters": { "type": "object", "properties": {} } }],
  "contextTokens": 131072,
  "outputTokens": 65536,
  "snapshot": null,
  "toolResults": []
}
```

The runtime emits `model` with a string `id`, messages, tools, `toolChoice`, and `purpose`. Messages carry `role`, string `content`, and optional `tool_calls` or `tool_call_id`. Each tool call has `id`, `name`, and a raw JSON `arguments` string. The host answers with `model_result`, the same `id`, string `content`, optional `tool_calls`, and `finish_reason` (`stop`, `tool_calls`, or `length`). Optional `reasoning_content` is preserved. Alternatively, the host returns `model_error` with the same `id` and a failure `code`.

The runtime then emits one of:

- `boundary`: an opaque `snapshot`, ordered `toolCalls`, and the latest assistant `content` for progress display.
- `final`: an opaque `snapshot` and verified nonempty assistant `content` from a completed DSH turn.
- `error`: a concise failure `code`. The process exits unsuccessfully.

`final` describes a completed agent turn, not an independent guarantee that the task's claims or effects are correct. Task verification remains part of the assignment and the host's completion policy. A response cut off by the model's output limit is an error, never a successful final answer.

The host persists a boundary before executing any tool. After executing or denying the ordered calls through its existing authority and effect ledger, the host starts a new process with that snapshot and exactly one matching receipt per pending call. Each receipt contains `tool_call_id`, string `content`, and optional boolean `isError`. Extra `role: "tool"` fields are accepted. Missing, reordered, duplicate, or extra receipts are rejected before inference.

The runtime seeds a new in-memory DSH session from the saved event history, appends the actual receipts with their original source references, closes the interrupted turn, and resumes. It does not call DSH's disk-session recovery path, which would manufacture unknown-outcome receipts before the host reconciles effects. If a host crashes during an effect, the host must reconcile its durable ledger before supplying the receipt. Replaying the same saved snapshot does not itself execute any effect.

A `cancel` input or termination signal aborts pending model requests and the DSH agent. Closing standard input before a result is a failure. Unknown or duplicate model response identifiers are rejected.

## Compaction and limits

The standard DSH token meter and basic compaction plugin summarize earlier history through the same host model adapter. The meter currently estimates text at four characters per token with structural overhead. It is not the selected model's exact tokenizer. The compaction threshold reserves the configured output allowance and additional headroom, and summaries request no tools. Output and thinking settings remain host-owned; this runtime adds no thinking-token cap or per-task tool-round cap.

Compaction reduces the model-visible conversation while preserving the full event history in snapshots. The 16 MiB protocol ceiling therefore bounds retained session history. An oversized snapshot fails explicitly rather than discarding effect receipts. A future snapshot-retention extension must preserve tool reconciliation and DSH source references before reducing the event log.

This first adapter supports text and structured tool calls. Image and file content blocks fail explicitly until a host-mediated representation is added. Host inference context limits and wire limits still apply. Model responses are bounded to 4 MiB, saved results to 6 MB, and app snapshots to 8 MB. Long final answers are retained without the previous 40,000-character report clipping. Oversized output fails explicitly. Progress text is shortened separately from the saved answer.

## Extending the runtime

Add DSH behavior through explicit imports and registered plugins. Tool additions belong in the host's schema and authority implementation. A new plugin must not introduce direct filesystem access, shell execution, credential discovery, or network inference outside the host bridges. Keep the pinned versions and lockfile aligned when upgrading DSH, then rerun the contract tests for resumed effects, cancellation, malformed calls, and compaction.
