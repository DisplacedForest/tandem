# Isolated Pi assistant prototype

This prototype embeds the official Pi agent-core SDK 1.0.4 in separate foreground and worker processes. Vera's existing Python TaskStore and Dispatcher own task identity, approval waits, cancellation, recovery and terminal state. It never mounts routes in the active engine or loads the native app's configuration.

The runnable transports are the inline deterministic mock and an explicitly selected native-helper mock. Pi's actual agent loop, validated tool calls and subprocess boundary run in these tests, but the mock does not measure model quality or local MLX performance. Every background request edits the same synthetic addition example inside that task's private workspace. It is not a general coding service.

## Run

Use the repository Python development environment with FastAPI, uvicorn, pytest and pytest-asyncio, and Node 22.19 or later. Dependencies are installed only in this directory:

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix prototypes/pi_assistant
python prototypes/pi_assistant/bridge.py --data-root /tmp/vera-pi-example --port 8769
```

The bridge binds only `127.0.0.1`. Choose a fresh private data directory. The UI can use `http://127.0.0.1:8769` and explicitly grant `/tmp/vera-pi-example/workspaces` as its artifact root. Keep the mock transport label visible. No GUI launch is required.

```sh
mise run pi-prototype-test
mise run pi-integration-test
mise run pi-native-integration-test
```

The integration task builds the separate UI and runs headless HTTP consumer checks against a fresh mock bridge. It kills the bridge after durable acceptance, reopens the same data, and verifies explicit UI recovery without resubmitting the accepted task. It also verifies approval, completion, output files, task-specific Stop and focused chat isolation. No visible window is launched.

A message beginning `/task ` delegates a synthetic background task. Other text produces a mock foreground reply. Approval is required before the worker starts. A second foreground message uses an independent process while the worker runs. Focused mode has no delegation tool.

## Native helper mock

After building with `mise run pi-native-integration-test`, start a fresh bounded experiment with:

```sh
python prototypes/pi_assistant/bridge.py --data-root /tmp/vera-native-pi-example --port 8769 --native-mock-helper prototypes/native-transport/.build/debug/VeraNativeTransport
```

This runs Pi's actual SDK loops through private pipes to the Swift helper, whose credential and HTTP implementations are injected fixtures. Python and Node receive typed results and synthetic usage, never a credential. The HTTP capability stays labeled `transport:"mock"` and adds `transport_detail:"native-mock"`. There is no live transport flag or environment override in the bridge. Task payloads and results retain their selected transport, and changing it during recovery fails closed.

The native experiment allows two foreground invocations and one worker invocation, four model rounds each, within a synthetic $1 accounting cap. It expires after ten minutes and never renews its own authority. Inspect the saved ledger and preserve its identity on interruption; do not reset it to bypass refusal. See the [helper contract](../native-transport/README.md). The native integration tests cover actual SDK tool calls, a second foreground reply during work, accounting, approval/decline, focused mode, pre-write cancellation, helper protocol failure, helper kill, and Python parent SIGKILL with descendant cleanup.

## HTTP contract, version 1

| Route | Contract |
| --- | --- |
| GET `/assistant/capabilities` | `protocol_version`, `foreground`, `worker`, `computers:false`, `transport:"mock"`, `workspace_root` |
| POST `/assistant/messages` | UUID `assistant_id`, `conversation_id`, `message_id`; `text`; `mode:"assistant"` or `"focused"`. Returns `message_id`, `reply_id`, `text`, `task_ids`. |
| GET `/assistant/messages?conversation_id=...` | `messages` with stable `id`, `role`, `text`, `task_ids`. Clients upsert by identity. |
| GET `/tasks` | Existing Vera paginated canonical snapshots. `limit` and `before` retain existing semantics. |
| GET `/tasks/events` | Existing SSE event IDs, `after` and `Last-Event-ID`. Reconcile canonical state after reconnect. |
| POST `/tasks/{id}/cancel` | Existing durable cancellation, plus active adapter polling and process-group termination. |
| POST `/tasks/{id}/decision` | `decision_id`, `idempotency_key`, `reply:{"approved":true}` or false. |

A task carries `worker_type:"pi_worker"` and a payload with assistant/conversation/originating-message UUIDs, objective, `workspace_ref:"task-private"`, and `transport:"mock"` or `"native-mock"`. Workspace scope is host-selected, never a model-supplied path. Decisions have `id`, `prompt`, `choices:["approve","decline"]`. Results contain `summary`, `artifacts:[{kind:"file",path,title}]`, and transport. Only `sum.py` is a granted filename. The UI must independently scope file opening to its explicitly configured workspace root.

Repeated identical message IDs return the saved answer; changed content conflicts. Interrupted foreground turns require inspection instead of automatic replay. Assistant and focused conversation identities cannot be rebound to another mode or assistant. The UI owns the stable assistant UUID and conversation mapping. These identifiers are integration fields, not ordinary display copy.

## Recovery and effects

The task database schema is unchanged. A separate private assistant journal stores turn receipts, worker attempt receipts, effect intent and transcript delivery identities. It uses SQLite FULL synchronization. The existing dispatcher lock fences a second owner.

Before a worker starts, its attempt is recorded. If it dies without a completion receipt, restart stops for a new decision. A recorded completion can finish the existing task without executing the worker again. Artifact writes record an intended content digest and previous-content digest before atomic replacement. Identical replay reconciles the current digest without writing again; divergent or externally changed effects are rejected. This is a bounded idempotent file operation, not a claim of exactly-once arbitrary external actions.

Results enter the transcript only after terminal task persistence, using one unique delivery row per task. Repeated reads or reopening return the same message identity. Exactly-once visible presentation also requires consumer upserts by that identity.

Workers inherit only PATH and LANG. Raw stderr is discarded. No shell, network, general filesystem, secret, memory or computer tools are exposed. Time, protocol-size and call-count limits are host-enforced. Stop terminates the process group, escalates to SIGKILL, and awaits the direct child before waiting for host callbacks. If a host callback ignores cancellation, cleanup retains ownership until it settles; a successor cannot replay that work. The SDK worker also exits its group on stdin closure when its supervisor dies. Deliberately detached hostile processes are outside this prototype's allowed tools and are not claimed to be sandboxed.

This is a single-user local test service. Browser origins and non-loopback Host headers are rejected; JSON is required for writes. There is no household authentication or remote-serving authorization. Do not expose it over a network or add arbitrary command tools without a separate sandbox and permission review.

## Dependency and durability decision

Official source: https://github.com/earendil-works/pi/tree/v1.0.4 . The audited tag resolves to `7c10bd4` (full revision in `dependency-audit.json`). Exact SDK package versions and all transitive integrity hashes are in package-lock.json. Installation disables lifecycle scripts. Provider factories and automatic credential discovery are not imported; the adapter supplies its own stream function and explicit tools. No Pi fork is needed.

The separate `@earendil-works/pi-durable` package at that tag is explicitly experimental. It owns a different conversation/task schema, offers replay policies, and lacks cross-process storage ownership locking. Recovery of replay-safe tools can bypass initial approval hooks. Its SQLite defaults use NORMAL synchronization. It has not been installed, executed, or used to migrate Vera data. Replacing Vera persistence is unnecessary for this proof.

## Cloud transport status

No paid model call is made by this implementation. Existing native smoke support permits fixed requests and the current app relay is research-specific. Neither exposes a general Pi tool-schema completion broker. The prototype refuses to export a saved key into Python or Node, widen that relay, or create a new Keychain grant.

See NATIVE_TRANSPORT.md for the isolated credential-owning transport and exact remaining authorization boundary. Actual cloud results, if subsequently authorized and observed, must be labeled OpenRouter results and cannot establish local MLX latency or quality parity.
