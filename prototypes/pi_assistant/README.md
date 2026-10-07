# Isolated Pi assistant prototype

This prototype embeds the official Pi agent-core SDK 1.0.4 in separate foreground and worker processes. Vera's existing Python TaskStore and Dispatcher own task identity, approval waits, cancellation, recovery and terminal state. It never mounts routes in the active engine or loads the native app's configuration.

The runnable transports are the inline deterministic mock and an explicitly selected native-helper mock. Pi's actual agent loop, validated tool calls and subprocess boundary run in these tests, but the mock does not measure model quality or local MLX performance. Every background request edits the same synthetic addition example inside that task's private workspace. It is not a general coding service.

## Start the separate prototype

After `mise run pi-prototype-test` builds and checks the isolated dependencies and UI, start the bridge and prototype window together:

```sh
python prototypes/pi_assistant/launch.py --mock \
  --data-root "$HOME/Library/Application Support/VeraPrototype/session-one" \
  --port 8769
```

Use the same folder and port to reopen its identity, drafts and tasks. The folder must be private, owner-owned and free of symlink paths. A first run requires an empty folder; the launcher never clears existing state. It pre-binds the loopback port, verifies the exact bridge instance and workspace before starting the UI, and never connects to an existing service on a busy port. Closing the prototype window or stopping the launcher shuts down its owned runtime processes. It does not start or replace installed Vera.

The launcher is explicitly mock-only. In Vera, send `/task Check addition` to try an approval, a synthetic worker and its output; focused chats stay separate. **Test runtime** remains visible. For a headless actual-UI consumer check, add `--contract-test` and use a fresh session folder. This runs the existing approval, foreground reply, artifact, Stop and transcript checks without a visible window.

If the launcher is killed abruptly, the bridge stops when its parent pipe closes. An already-open prototype window may remain disconnected; it retains the session lock, preventing another launcher from sharing its state. Close that window before reopening the same session. No automatic restart or message replay occurs.

## Run components separately

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

## App-owned broker mock

Run `mise run pi-app-broker-test` for the headless app-owned experiment. It builds the isolated Vera executable, injects a fixture model inside that process, and starts the Python runtime through owned private pipes. The test controller uses those pipes to authorize exact message/task, assistant, conversation, role, mode and disposable profile bindings. Python still owns task persistence, approvals, tools, effects and result delivery. No installed app, saved profile, credential, model HTTP client or paid provider is used.

The private entry point is `Vera --pi-broker-mock --root <private-experiment-directory> --repo <checkout> --python <absolute-python> --node <absolute-node> --port 0`. Both standard streams must be owned pipes, not a terminal. The test controller in `app_tests/test_app_broker.py` demonstrates this contract. It receives an ephemeral HTTP capability through the private bootstrap, never through arguments, environment or saved files. All routes require that capability, which expires after ten minutes. The existing standalone UI does not yet consume this new startup channel. Its mock launcher remains a separate test mode.

The app ledger retains completed model receipts and uncertain reservations across restart. It admits at most one foreground and one worker completion at a time, twelve calls total and four per message/task, within a synthetic one-dollar allowance. Cancellation, timeout, invalid output or uncertain persistence fences further calls. Duplicate completed requests return the validated saved receipt. Reopening preserves profile identity but grants no authority automatically. These are synthetic admission/accounting tests, not integration with a configured shared inference coordinator or the real paid-test spend ledger.

The runtime manifest binds the selected Python/Node binaries, prototype adapter sources and npm lockfile on reopen. It is not a complete measurement of installed Python packages, Node modules, the shared engine or a sandbox against hostile same-user code. Dependencies still use the existing reviewed, pinned setup. Process tests cover actual Pi foreground/worker loops, authenticated approval, a second reply during work, one delivered artifact, Stop, app/runtime SIGKILL, restart, malicious scope/channel requests, receipt replay and owned-descendant shutdown.

There is no live selector or credential-owner implementation in this path. A usable live assistant still requires the separately reviewed saved-profile provider operation inside the normal Vera app, lifecycle/UI integration, actual shared admission and spend accounting, and authorization to run the resulting app. This experiment does not resolve or bypass the separate helper's denied credential access.

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

A task carries `worker_type:"pi_worker"` and a payload with assistant/conversation/originating-message UUIDs, objective, `workspace_ref:"task-private"`, and `transport:"mock"`, `"native-mock"` or `"app-owned-mock"`. Workspace scope is host-selected, never a model-supplied path. Decisions have `id`, `prompt`, `choices:["approve","decline"]`. Results contain `summary`, `artifacts:[{kind:"file",path,title}]`, and transport. Only `sum.py` is a granted filename. The UI must independently scope file opening to its explicitly configured workspace root.

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


## Integrated app candidate

The app executable can own the assistant UI, Python durable runtime, Pi SDK foreground and worker loops, provider operation, admission client and accounting together. This candidate uses explicitly injected credentials, provider replies and admission responses. It never reads Keychain or calls a real provider.

Build and run the headless workflow first:

```sh
mise run mac-build pi-prototype-deps
python prototypes/pi_assistant/candidate.py --mock --data-root /tmp/vera-app-candidate-check --contract-test
```

To open its separate test window, use a fresh folder and omit `--contract-test`:

```sh
python prototypes/pi_assistant/candidate.py --mock --data-root /tmp/vera-app-candidate-ui
```

The app starts and stops its own authenticated loopback bridge. A persistent runtime identity permits a new ephemeral port on reopen. The selected-profile operation uses committed profile and credential state, excludes environment overrides, and checks the same binding around execution and receipt replay. The model receives no credential; Python and Node receive only typed requests, replies and explicit task authority. Worker authority follows a confirmed durable approval. Closing the window terminates owned runtime descendants.

The foreground and worker operations use the existing native admission client, plus shared durable reservations and provider usage receipts. Synthetic accounting starts at zero and is separate from any real test-spend ledger. An interrupted model request remains uncertain and blocks new provider work. UI inspection and archival of an unconfirmed reply do not reconcile or erase that hold. A saved completion receipt can be displayed without repeating the operation.

The live activation boundary remains closed. A future reviewed owner must supply the app's existing committed selected-profile operation, actual admission service and reconciled cumulative spend baseline through the same interfaces. It must keep credentials in the app and refuse redirects or profile drift. The fixed model, provider price ceiling and reply limits need a bounded live compatibility check before use. There is no live candidate flag, credential grant, signing change, installed-app replacement or deployment command in this launcher. Mock results establish neither cloud quality nor local MLX performance.

`mise run pi-app-broker-test` includes the integrated app workflow, selected-profile/receipt regressions, refused approval, missing acknowledgement, invalid flag and nonregular-file checks. The workflow drives the same UI store used by the candidate window; it does not establish visual or accessibility QA.
