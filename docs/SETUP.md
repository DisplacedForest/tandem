# Setting up Vera

This is the end-to-end path from nothing to a working installation: backend, chat, native app, then the optional layers — integrations, veins, and satellite services. Each stage works without the stages after it, and the system reports what is and isn't configured.

**The stack** (each component is a URL in config; topology is up to you):

| Piece | What it is | Required? |
|---|---|---|
| An OpenAI-compatible LLM server | llama.cpp / llama-swap / vLLM / Ollama / a hosted API — anything serving `/v1` | Yes |
| **Vera.app** (this repo) | The native macOS client with direct streaming text chat and local history | Recommended |
| **vera-api** (this repo) | One FastAPI container that lights up the ambient and experimental surfaces (Pulse, veins, weather, kitchen, research, knowledge collections, scheduler, actions) | Optional |
| Integrations (Home Assistant, Grocy, Mealie, Overseerr, Unraid, SearXNG, Reddit, Embeddings) | Each unlocks a capability | No |
| Satellite services (voice, image, vision, coder) | Reference implementations of documented HTTP contracts | No |

> **Fastest path on a Mac.** Install the Mac app and point onboarding at an OpenAI-compatible endpoint ending in `/v1`. Text chat needs nothing else. For the optional ambient tier, open Settings, Services, Engine and choose **On this Mac**. The app downloads the packaged engine for its own version, verifies it, and runs it as a background service on `127.0.0.1`.

For optional cloud model evaluation, see the [OpenRouter setup and synthetic smoke test](OPENROUTER.md).

## 1. Prerequisites

- **An LLM endpoint** — any standard OpenAI-compatible `/v1` server with a capable instruct model.
- **Docker** (optional) on any Linux/macOS host for vera-api.

## 2. vera-api

```sh
git clone https://github.com/DisplacedForest/vera.git && cd vera
cp .env.example .env     # fill in what you run — everything unset degrades gracefully
docker compose up -d     # pulls the released ghcr.io/displacedforest/vera-api image
```

Compose pulls the released image by default. To run from source instead, uncomment `build: services/vera-api` in `docker-compose.yml` and use `docker compose up -d --build`.

### Run the engine without Docker (macOS arm64)

Every release ships a packaged engine binary alongside the image. Download `vera-api-macos-arm64.zip` and its `.sha256` from the GitHub Release, verify with `shasum -a 256 -c vera-api-macos-arm64.zip.sha256`, unzip, and run `./vera-api/vera-api`. It serves on `127.0.0.1:8089` and keeps its data in `~/.vera/data`; `VERA_DATA_DIR`, `VERA_BIND`, and `VERA_PORT` override those defaults. Configuration is the same `.env` surface either way (export the variables or launch through a wrapper that sets them).

Then read the **config report** — vera-api prints exactly what is wired at startup, and it is the first thing to check when something is off:

```sh
curl localhost:8089/health
docker compose logs vera-api | head -60
```

### Durable task API

The task engine runs inside the existing vera-api process. `TASK_DB_PATH` defaults to `tasks.db` under the resolved `VERA_DATA_DIR`, so Docker and the packaged Mac engine use the same storage behavior. Existing stores are unchanged. Run one API process per task database: a process lock rejects a second dispatcher. Keep the database and its WAL together, and use SQLite's backup API for live snapshots.

The `research` worker is registered when the API starts. `GET /tasks` returns persisted tasks and available worker types; `POST /tasks` returns HTTP 503 for an unconfigured worker without creating a record. Native chat still connects directly to its model endpoint. The queue coordinates native inference but does not provide household access controls. Keep the API within the same trusted deployment boundary as its other capabilities.

| Endpoint | Contract |
| --- | --- |
| `POST /tasks` | JSON `worker_type`, `payload`, and required `idempotency_key`. An identical retry returns the original task; conflicting reuse returns 409. |
| `GET /tasks` | Newest first, `limit` from 1 to 200. Pass the previous page's last task ID as `before` for stable pagination, including equal timestamps. |
| `GET /tasks/{id}` | Current lifecycle, checkpoint, result, and pending decision. |
| `POST /tasks/{id}/cancel` | Stops queued or waiting work immediately; running work stops at the next step boundary. Repeated cancellation is harmless. |
| `POST /tasks/{id}/decision` | JSON `decision_id`, `idempotency_key`, and `reply` object. Only the current decision accepts a new reply. Identical retries do not requeue work twice. |
| `GET /tasks/events` | SSE events with global numeric IDs. Reconnect using `Last-Event-ID`; optional `task_id` filters events without changing cursor meaning. `after` supplies an initial cursor when the header is absent. |

The stream replays committed events in ascending order before following new events. IDs can have gaps and clients should deduplicate by ID. An invalid cursor returns 422, a cursor beyond the current store returns 409, and a cursor from another task is valid within the same database. Events are append-only, have no retention limit yet, and emit a keepalive during idle periods. Do not reuse a cursor after switching or replacing the database.

Each worker step atomically saves its checkpoint, lifecycle and event. Recovery returns interrupted running tasks to the queue at their last committed checkpoint; a pending cancel becomes canceled. Queued, blocked, decision-waiting, and terminal tasks retain their state. Eligible steps run FIFO and requeue behind waiting work after yielding. Unknown worker types stay queued until their implementation is configured. A blocked task needs a guarded `TaskStore.resume`; an enrolled native app can resume its own native-unavailable checkpoint. Other user-facing retries use a decision.

Worker implementations register an async `step(task)` with `tasks.register_worker` before startup and declare a finite timeout in seconds. An optional payload validator rejects invalid new requests with HTTP 422 before persistence. Validators must be synchronous, fast local schema checks without I/O because they run inside the creation transaction. Existing request replay and conflicting key reuse are resolved before validation, and validators cannot rewrite the saved payload. Optional immutable tool names describe the trusted worker implementation; they do not grant model-selected access or create a sandbox. A step receives a snapshot with `id`, `payload`, `checkpoint`, and `decision_reply`, and returns `task_store.StepResult` with a lifecycle, checkpoint, optional result, and event data. A decision reply is the supplied object and is cleared by the next committed step. New decisions receive unique server-owned IDs. Payload, checkpoint, result, decision and reply objects each have a 256 KiB encoded JSON limit; event data has a 16 KiB limit. Values must be valid JSON without nonfinite numbers.

Timeouts and worker errors record failure with the last checkpoint. Cancellation has a bounded grace period. A worker that keeps running makes the task engine unavailable and retains database ownership until it exits or the process dies; its late result is discarded. Shutdown wakes the dispatcher and fences claims only after execution ends. Steps must be asynchronous and must not block the event loop. Storage commits retry bounded transient errors without rerunning the step; persistent errors make task endpoints unavailable until the engine restarts after the underlying problem is fixed. This API does not provide exactly-once external effects. Workers must not perform side-effecting tools until a separate durable action protocol handles their crash windows and approval boundaries.

Submit background research with `POST /tasks`:

```json
{
  "worker_type": "research",
  "payload": {"query": "What evidence answers this question?", "use_rag": false},
  "idempotency_key": "research-request-1"
}
```

Research uses the existing configured model and web search integrations. `use_rag` defaults to `true` and includes the existing local document store; set it to `false` for web-only work. `query` accepts 1 to 5,000 characters, `subquestions` accepts 1 to 5 (default 4), and `pages_per_q` accepts 0 to 4 (default 2). Each step has a 180-second deadline. Checkpoints retain up to 14 sources with 1,500 characters of evidence each. Source metadata, errors, and the report are bounded to fit the task store.

Read the saved report and source list from `result` on `GET /tasks/{task_id}`. Progress events include numbered source titles without full source text. Report checks require numeric citations to refer to gathered sources; they do not verify every claim. If there are no usable sources or the model returns an unusable report, the task waits for a decision and preserves its evidence. After resolving the cause, submit `POST /tasks/{task_id}/decision` with the current `decision_id`, a new `idempotency_key`, and `"reply": {"action": "retry"}`. Cancel remains available through the normal task endpoint. A restart can repeat an interrupted read-only search or model call, but committed steps and their source events are not repeated. `POST /research` retains its existing blocking response contract for existing API callers. Native foreground chat no longer advertises it.

### Saved API keys

Opening Vera and saving unrelated settings leave existing Keychain items unchanged. Explicit key edits update the existing item in place; clearing an edited field removes only that credential. A denied read does not mean a key is missing and never authorizes deletion. Failed edits remain available to retry, with a visible error in endpoint and vision-bridge settings. Legacy configuration keys migrate only on Save after a confirmed missing Keychain item; migration conflicts preserve the original configuration.

This preserves Keychain item continuity. Ad-hoc app builds still have changing code identities, so this change alone does not remove prompts caused by replacing the signed app.

### Native session recovery

The composer offers Chat and Continuous per conversation. Chat serializes that conversation's answers, and a queued follow-up captures its completed predecessor context when it starts. Continuous accepts independent turns with completed context and clearly marked prior unfinished requests. Switching modes affects future sends; existing queued work keeps its order and mode.

The app persists the user message, reply placeholder, and pending turn in one local SQLite transaction. Two foreground turns may run across app instances, with at most eight pending messages. A running turn has a five-minute outer deadline in addition to individual tool limits. Claims are atomic and bind the original endpoint, model, saved profile, options, tool selection, and attachment route. Changed or unavailable settings pause the saved message instead of sending it elsewhere. Text turns do not depend on an unused vision bridge. A keyed bridge without a stable saved binding requires a new message after restart when an image actually uses it.

Recovery distinguishes never-sent messages from requests that might already have reached a provider or tool. It detects a dead owning process and interrupts that answer, including when another app instance remains open. Tool dispatch writes its uncertainty marker before execution. Retry refuses to replay uncertain actions, even when the tool did not require a confirmation dialog. Explicit retries of older interrupted history keep their original message IDs and use only replay-safe research tools. If the final state cannot save, the app retains that answer's local ownership and retries only the state write. It does not repeat provider or tool work, and the queue continues once storage recovers. Provider credentials are not stored in turn records.

### Native background research

Enable Deep research in the native tool settings and configure the Vera engine URL to expose `create_background_task` during typed chat. Its required fields are `worker_type` (currently `research`), `objective`, and `deliverables`. Foreground chat uses this durable handoff for explicitly requested research. Chat retains short web lookups; Continuous does not advertise blocking search or research. Background handoff needs durable local chat storage. It is not advertised when the engine is unset. The original chat shows a persistent task card with progress, Stop, and an explicit Retry only when the engine offers it. Completion adds one read-only cited report. The app restores cards after restart, uses one event connection per engine, and refreshes canonical task snapshots before saving progress. Known task IDs are never recreated after a missing-task response. Saved reports remain readable when the engine is unset; task actions are then disabled. A fresh conversation without an engine has no task surface. Voice handoff remains separate.

The app saves a unique creation key, exact request, original conversation/message references, engine URL, and model profile binding in its existing SQLite database before sending the request. Repeated equivalent calls within the same user turn reuse that record. Restart and lost-response recovery replay the original body and key. Changing engine URLs never sends an old request to the new engine. Deleting a conversation marks unfinished handoffs for cancellation, including requests whose creation acknowledgment was lost. Once the orphaned request resolves to a terminal outcome, its content is removed; only a minimal reservation tombstone remains.

Native-enrolled research uses web sources only. The API asks the enrolled app for bounded text generation through `/tasks/{id}/native/ready` and `/tasks/{id}/native/result`. Readiness is required before acquiring background inference capacity. The generation request exists only while that capacity is held, and expires with it. These relay messages contain research prompts and bounded output, but never provider credentials. The API uses a credential-free provider URL solely to identify shared inference capacity. The app chooses the execution endpoint and model from its saved binding, rejects extra relay fields, refuses redirects, and supplies no tools or images to background generation.

The original saved profile must still exist with the same endpoint and model. Active-profile changes do not retarget existing work. Credential lookup is noninteractive; a locked or missing required credential leaves work waiting. Each task pins a finite generation request allowance (four by default), a 64 KiB serialized text-input limit, and a 1,024-token output limit. Completed generation responses are cached locally. An uncertain request after a crash remains charged to its allowance; it is never resent automatically under the same generation identity. A user retry stages a new attempt within the same allowance. Exhaustion stops the task without a misleading retry option. These are request and token limits, not a dollar-cost estimate; provider account limits remain authoritative.

Cards and report blocks are saved separately from foreground reply text, so a later stream update cannot erase a completed report. Spoken text never incorporates a report, task card, or display link. The report view accepts only web link actions without embedded credentials and does not fetch embedded Markdown images. Existing voice playback reuses URL cleanup, but this does not enable native voice handoff.

Offline tests use temporary databases and a synthetic loopback provider. `mise run native-task-test` builds the app and exercises typed handoff, foreground conversation, lost acknowledgments, cancellation, concurrent app processes, and a process killed after sending a generation request. It also checks transcript restoration, replayed completion, persisted retry keys, stream reconnects, cursor reset, and cancellation responsiveness with eight enrolled tasks. It does not read live credentials or call a paid provider.

## Inference admission

The engine and native app share a generation admission policy. The actual model request still goes directly from the Mac to its configured endpoint with its existing Keychain-owned credential. `POST /inference/admission` reserves a bounded logical window, and `POST /inference/admission/{request_id}/release` retires it after local transport cleanup. The control messages carry a fresh request UUID, a SHA-256 endpoint fingerprint, priority, and requested duration. They contain no provider key, messages, prompt, model output, or credential-bearing URL. Admission metadata lives beside tasks in `tasks.db` and follows `TASK_DB_PATH`.

Native chat constructors used by the app, including settings reloads and vision bridging, explicitly join foreground admission whenever a Vera engine is configured. Automatic native memory extraction joins the background class; explicit memory-change requests join foreground. Embeddings and reranking bypass this generation policy. Standalone native chat without an engine retains its direct path. A configured engine that is unreachable or lacks the admission API produces a connection error rather than silently bypassing scheduling; use a matching engine version. This is the existing trusted engine boundary, with no new authentication system.

| Variable | Default | Meaning |
| --- | --- | --- |
| `INFERENCE_BACKGROUND_SLOTS` | `1` | Maximum admitted background generations per resource, from 1 to 32. |
| `INFERENCE_BACKGROUND_SECONDS` | `20` | Total deadline for one background generation. |
| `INFERENCE_FOREGROUND_SECONDS` | `600` | Upper bound for foreground generation. Native chat requests 120 seconds; existing API calls retain their shorter declared limits. |
| `INFERENCE_CLEANUP_SECONDS` | `2` | Additional logical lease lifetime for transport cancellation cleanup. |
| `INFERENCE_PENDING_SECONDS` | `10` | Pending request lifetime, refreshed only while it is still waiting. |
| `INFERENCE_RESOURCE_GROUPS` | `{}` | Optional JSON mapping of endpoint fingerprints to a shared group name. |

Endpoint identity lowercases scheme and host, removes default ports and trailing slashes, and hashes the origin plus base path. User information, query strings, and fragments are excluded. Models served by the same base URL share capacity. Distinct URLs sharing a generation resource need an explicit common group; the engine cannot infer hardware placement. Use the same canonical base endpoint in the native app and backend, or map both fingerprints to one group.

A foreground intent is persisted before the native provider request begins. Queued background work cannot pass a pending or active foreground reservation. An already admitted background request is not preempted. With multiple background slots, foreground waits for the current admitted wave, bounded by the largest remaining generation window plus cleanup allowance, not by the depth of the background queue. `model_client.complete` routes through admission automatically; durable worker context selects background, and interactive API call sites can explicitly pass `priority="foreground"`. Untagged legacy API generation retains foreground treatment and its declared duration; preexisting scheduler, Pulse and authoring surfaces outside the durable worker runtime are not automatically reclassified as background. Individual generation timeouts apply inside the worker's separate step deadline, including repair calls.

Successful idle foreground admission has no scheduler sleep or queue delay. Native coordination adds a control round trip before generation and a release round trip afterward; it does not promise unchanged total network latency. The native integration tests report measured elapsed and admission-handler time against a local synthetic endpoint.

Repeated acquisition uses the same UUID and cannot renew an admitted generation. Lost responses can be retried safely; cancellation before acquisition creates a tombstone that rejects a delayed grant. Pending intents and unexpired admitted windows survive an API restart before new background work can proceed. Clients measure elapsed time with a monotonic clock and conservatively subtract the whole admission round trip from the server's remaining budget, so Mac and engine clocks need not be synchronized. Within one engine process, expiry is monotonic. After a restart, persisted wall-clock remaining time is clamped to the original configured duration plus cleanup allowance; a host clock correction across a restart can shorten or extend that recovery window within this bound.

Clients stop accepting output at the generation cutoff and request local cancellation. A late response or frame is discarded. A lease expires at its fixed deadline plus cleanup allowance even if release is lost or the client exits. Expiry releases scheduling capacity only: it does not claim the remote provider has stopped computing. The policy makes no GPU-preemption or remote-termination guarantee. A worker that refuses cancellation can still make its task dispatcher unavailable, while the independent foreground admission route remains usable after the bounded lease expires.

### The `.env` walkthrough

`.env.example` is fully commented and is the authoritative reference; every variable the stack reads is in it (a test enforces this). The variables that matter first:

| Block | Variables | What it unlocks |
|---|---|---|
| Core LLM | `VERA_BASE`, `VERA_MODEL` | Everything generated: Pulse briefings, card text, judges |
| Web search | `SEARXNG_BASE` (+ optional `PLAYWRIGHT_WS`) | Research, Pulse sourcing, watcher veins, and the Mac app's web search and deep research chat tools (the app reaches them through its `vera_api_base` setting, never SearXNG directly) |
| Identity | `VERA_OWNER_ID`, `VERA_OWNER_NAME`, `HOME_LOCATION_NAME`, `HOME_TZ`, `WEATHER_LAT`/`LON`, `TEMPERATURE_UNIT` | Personalization, the owner id that cards/read marks/profiles are keyed by (defaults to `owner`), schedules in your timezone, weather anchoring |
| Coder | `DREAM_BASE`, `DREAM_MODEL`, `DREAM_TOOL_PROTOCOL` | Cross-model claim auditing + fact verification |
| Audit hooks | `AUDIT_WAKE_URL`, `AUDIT_RELEASE_URL` | Cross-model claim audits on every Pulse run when the audit model is served on demand (POSTed before/after the batched end-of-run audit; unset = no hook calls) |
| Embeddings | `VERA_EMBED_URL`, `VERA_EMBED_MODEL` | Document knowledge collections (upload, indexing, retrieval that grounds research and chat) plus Profile Graph dedup and Pulse novelty math; unset, collection management still works while indexing and retrieval report unconfigured |
| Image gen | `VERA_IMAGE_BASE`, `IMAGE_PROTOCOL` | Generated cover art on Pulse cards |
| Vision review | `VERA_VISION_BASE`, `VERA_VISION_MODEL` | Optional Pulse cover-art review and one retry |
| Scout sources | `GITHUB_API_BASE`, `ARXIV_BASE` (default to public endpoints); Reddit is a plugin (`REDDIT_CLIENT_ID`/`REDDIT_CLIENT_SECRET`, register a script app at reddit.com/prefs/apps) | Pulse candidate search across github/papers/reddit; news and local ride `SEARXNG_BASE`, weather rides `WEATHER_LAT`/`LON` |

Two conventions:

- **Endpoints are `*_BASE`, credentials are `*_KEY`.** Older names still work; the config report flags them with their replacement.
- **Unset means off, visibly.** A capability without its endpoint reports itself as not configured — it never fakes output and never affects other capabilities.

Integrations (Home Assistant and the rest) can be set in `.env` for headless installs; the app's integration store in step 3 is the recommended path.

### Reference corpus sync and backups

Two host scripts cover the standing ops work, and each documents its own environment in its header:

- `scripts/rag-sync.py` reconciles a folder tree of reference documents into vera-api document collections: it walks `REFERENCE_ROOT/<domain>/`, uploads new and changed files, removes deleted ones, and is safe to re-run. It needs the vera-api base URL, passed as `--vera-api-base` or read from `VERA_API_BASE`, and has no default. `scripts/vera-rag-sync.sh` is the cron wrapper: it exports `REFERENCE_ROOT`, and when `VERA_API_BASE` is not already in the environment it reads it from the deployed vera-api env file (`VERA_API_ENV_FILE`).
- `scripts/vera-backup.sh` is a reference nightly backup. It captures vera-api's `/data` stores out of the running container as two artifacts: `vera-data.tgz` with the volume's non-database tree, and `vera-data-dbs.tgz` with consistent SQLite snapshots taken through the backup API and integrity-checked before archiving. Restore by extracting the first into `/data`, then the second over it. The script archives the container's config alongside them and writes checksums and a manifest.

## 3. The Mac app

**From a release** (macOS 26 Tahoe or later; earlier macOS can run releases up to 0.2.x): download `Vera.app.zip` from the [latest release](https://github.com/DisplacedForest/vera/releases/latest), unzip, and drag `Vera.app` to Applications. The app is ad-hoc signed (no notarization), so macOS quarantines the first launch — right-click → **Open** once, and it runs normally from then on. The app checks Releases and can update itself in place.

**From source** (Swift toolchain):

```sh
cd apps/vera-mac
swift build -c release
scripts/deploy.sh    # packages Vera.app and installs it to /Applications
```

### Stable signing for local builds

`apps/vera-mac/scripts/package.sh` builds a bundle without installing or launching it. Packaging uses ad-hoc signing unless a local identity is configured. Repeated ad-hoc builds can require new Keychain access approval because their signing identity changes with the executable. A dedicated local certificate gives successive builds a stable designated requirement; existing items may still need a one-time approval when changing from ad-hoc signing.

Create a dedicated certificate with Apple's [Certificate Assistant](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac) in Keychain Access. Choose a self-signed identity and the Code Signing certificate type, use an RSA key of at least 2048 bits, and store it in the login Keychain. Keep its private key there. Leave trust and access controls at their defaults and complete any macOS security prompt yourself. This local setup does not require setting Always Trust or exporting a private key. It does not provide Developer ID notarization or Gatekeeper distribution approval. Apple's [code-signing guide](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) explains how designated requirements identify successive versions.

Find the certificate's exact SHA-1 fingerprint with `security find-identity -p codesigning`. Save the nonsecret build settings as JSON at `~/.config/vera/signing.json` (or `$XDG_CONFIG_HOME/vera/signing.json`):

```json
{
  "identity": "REPLACE_WITH_40_CHARACTER_CERTIFICATE_FINGERPRINT",
  "keychain": "/absolute/path/to/login.keychain-db"
}
```

`keychain` is optional; when supplied it must be an existing absolute file path. The file is parsed as data, never executed. `VERA_SIGNING_CONFIG` selects another configuration file, and `VERA_SIGNING_IDENTITY` and `VERA_SIGNING_KEYCHAIN` override its values. An explicit identity must be its exact fingerprint. Invalid configuration, missing keys and signing failures stop packaging instead of silently falling back. `VERA_SIGNING_IDENTITY=-` explicitly selects ad-hoc signing. No build command creates certificates, changes trust, unlocks Keychains, or alters key access controls.

To inspect a packaged build, run `codesign --verify --deep --strict --verbose=2 build/Vera.app` and `codesign -d -r- build/Vera.app` from `apps/vera-mac`. Compare the designated requirement of two separately packaged builds before replacing an installed app. Keep the same certificate for future local builds; replacing it also changes the identity.

First launch runs **onboarding**. Give the endpoint a friendly saved name, enter its OpenAI-compatible URL ending in `/v1`, and add an optional API key. The key is stored in the Mac keychain. Discover models, inspect every returned identifier, choose one explicitly, review the local system prompt, decide whether to enable local memory, and inspect the native tool picker. The guide can be skipped and resumed from Settings, Endpoints. A valid configuration from an earlier release migrates into a saved endpoint and opens the app normally. Native conversations and approved memory live in `~/.vera/vera.sqlite`. A fresh native install starts with empty history and memory off.

Settings, Models keeps the last successful discovery result, shows the active model and whether it was restored, recommended, or chosen by you, and distinguishes an empty response, unusable model entries, authentication failure, network failure, and malformed data. Refresh never clears a known selection just because discovery fails. Settings, Persona holds the prompt library: personas with one active selection, user context, and reusable prompts, each with revision history and markdown import and export. Settings, Tools clearly separates callable tools from unavailable integrations and persists enabled choices. Apple Reminders starts disabled. Enabling it deliberately requests macOS Reminders access. Denied or unavailable tools are omitted from model requests even when their saved preference remains on.

With a vera-api URL configured (Settings, Services), the Knowledge area manages document collections stored in the engine: create collections, add txt, md, pdf, docx, or html files, watch per-file index state, and reindex or remove files. Any chat can ground its answers on selected collections through the chip above the composer; replies cite the retrieved passages and the sources row names the collection and file behind each citation. Without a vera-api URL the area shows its unconfigured state and chat shows no knowledge controls.

### Migrating Open WebUI knowledge collections

If you are moving off an existing Open WebUI instance, its knowledge collections can be
migrated into the vera-api document store in one pass:

```bash
python3 scripts/migrate_owui_knowledge.py \
  --owui-base http://your-owui-host:PORT \
  --owui-key YOUR_OWUI_API_KEY \
  --vera-api-base http://your-vera-api-host:PORT \
  --dry-run
```

Drop `--dry-run` to run it for real (the flags also read from `OWUI_BASE`, `OWUI_API_KEY`,
and `VERA_API_BASE`, the same base URL the reference corpus sync uses). The script recreates each knowledge base as a vera-api collection,
downloads every stored file, and uploads it through the documents ingestion endpoints, so
the native engine re-chunks and re-embeds everything with your configured embeddings
integration; no vectors are copied and the Open WebUI instance is never modified. It
requires the embeddings integration to be configured first and stops with a clear message
otherwise. Re-running is safe: files already present with identical content are skipped,
and the report lists everything created, uploaded, skipped, or failed. Chat history is not
migrated; the native store starts fresh by design.

Apple Reminders is the first native tool surface. A standard tool-calling endpoint can list reminders, create reminders, and complete a reminder by the identifier returned from a list call. These operations run through EventKit inside the Mac app and do not need vera-api or the standalone bridge service. They are available only during an explicit chat turn. Pulse, scheduled work, voice, and other autonomous paths cannot invoke them.

Each call renders as a pending, succeeded, or failed activity chip. Expand it to inspect the JSON request and result. Activity is stored with local conversation history without endpoint credentials or authorization headers. Unknown tools, disabled or unavailable tools, invalid JSON arguments, and calls past the loop limits do not execute. Their bounded error result is returned to the model. Tool execution is bounded to four rounds, eight total calls, and two actual web searches. A reached limit triggers one bounded synthesis without tools. If synthesis cannot answer, the transcript retains useful evidence as an unfinished answer with follow-up or retry controls. A tool failure, malformed stream, or endpoint outage also preserves received text and activity.

Settings, Model also holds each model's capability profile and the optional vision bridge. The profile (accepts image input, supports tool calls, supports streaming replies, images per request) defaults from a bundled name-pattern table of known vision-model families and can be overridden per model; the pane names which pattern matched or that your override is active, and Use defaults clears an override. The profile is enforced at request time: a model marked without tool support receives no tool schemas, a model marked without streaming gets one complete non-streamed response, image history is trimmed to the per-request limit, and a model marked text-only never receives image parts, including images from earlier turns after a model switch. The vision bridge is any separate OpenAI-compatible vision endpoint (base URL ending in `/v1`, model id, optional keychain-stored API key; `VERA_VISION_BRIDGE_BASE`, `VERA_VISION_BRIDGE_MODEL`, and `VERA_VISION_BRIDGE_API_KEY` override the saved values). When the active model does not accept an attached image, a configured bridge describes it and the description enters the request as labeled context with the bridge model named on the turn; without a bridge the app asks whether to send the message without its attachment. Attachments only ever leave the machine toward the model endpoint or the bridge you configured.

Voice and MCP remain unavailable in the native chat path.

Continuing a Pulse card into chat is native and local. The first continuation of a card re-reads `GET /pulse/cards` and then stores the card's text, sources, and provenance in the local database, so vera-api must be reachable only for that first step. After that the conversation opens offline, survives the card's expiry, and is reused by later continues of the same card. Card images are not cached locally.

### Custom chat tools

Chat tools beyond the built-ins are configuration, not code. Drop a JSON file in
`~/.vera/tools.d/` (next to `config.json`; `VERA_CONFIG_DIR` relocates the whole directory)
and the app loads it at startup and again whenever Settings saves. Each valid file becomes
a native tool: a toggle appears in Settings, Tools, the model is offered the tool when it is
enabled and available, calls execute over HTTP, and each call renders as an activity chip
in chat like any other tool. A malformed file is skipped, with the reason shown in Settings.

A declaration is one JSON object per file. For example, a tool over a home inventory
service:

```json
{
  "name": "list_inventory_items",
  "title": "List inventory items",
  "description": "Looks up items in the household inventory service by name or location. Use this when the user asks what is in stock or where something is stored.",
  "parameters": {
    "type": "object",
    "properties": {
      "query": { "type": "string" },
      "in_stock_only": { "type": "boolean" }
    },
    "required": ["query"],
    "additionalProperties": false
  },
  "endpoint": "/inventory/items",
  "method": "GET",
  "confirmation": "none",
  "timeout_s": 20,
  "enabled": true
}
```

- `name`: the unique function name the model calls.
- `title`: the short label shown in Settings and in the activity chip.
- `description`: what the tool does and when to use it, written for the model.
- `parameters`: a JSON Schema object. The supported subset is string and boolean
  properties, plus `required` and `additionalProperties: false`.
- `endpoint`: an absolute URL, or a path starting with `/`, resolved against the
  configured vera-api base URL. A path-relative tool stays unavailable until that URL is
  set.
- `method`: `GET` sends the arguments as query parameters; `POST` sends them as a JSON
  body.
- `confirmation`: `"none"` runs the call immediately; `"required"` asks in the chat UI
  before the request fires.
- `timeout_s`: optional, seconds before the call is abandoned (default 20).
- `enabled`: optional, default true.
- `json_fields`: optional, POST only. Maps a declared string property to a request body
  field, and the string must then contain a JSON object, for example
  `"json_fields": {"filters_json": "filters"}`. This lets a tool accept a nested object
  while the parameters stay within the string and boolean subset.

The response comes back to the model as tool data: JSON is preferred, plain text is
tolerated, and it is held under a size cap. A non-2xx response shows in chat as a failed
tool call with its status. Deleting a declaration, or setting `enabled` to false, removes
the tool starting with the next message.

The app bundles a few declarations this way: an actions surface, skill authoring, and a
recurring-watch author that drafts a vein from a plain chat request and saves it only
after you agree in the conversation. All of them ride vera-api routes and activate once
the vera-api base URL is configured.

### Native personal memory

Settings, Memory controls the optional native personal-memory feature. It starts off after upgrade. Approved records stay in the Mac app's local database and are organized in the Memory Library as **You**, **Topics**, **Areas**, and **People**. A compatible embeddings model enables semantic recall. A compatible chat model can create bounded proposals from completed turns and natural-language change requests. Missing or failed optional models leave ordinary chat usable.

All generated changes wait in the Memory review queue. Vera does not automatically create, update, merge, suppress, or prune approved memory. Episodic memory requires an absolute expiry date, stops appearing in recall after that date, and is removed by an automatic groom once the date has passed, with each removal recorded in the audit trail. A conversation can be excluded from suggestions through its sidebar menu.

See [Native memory](NATIVE_MEMORY.md) for the recall budgets, the privacy boundary, and the behavior it guarantees.

### Conversation ingestion (opt-in)

vera-api's Profile Graph learns from conversation transcripts. Alongside the scheduled pull sources, `POST /conversations/ingest` accepts batched transcripts pushed by a client (each with a stable `conv_id`, a unix `ts`, and role/text messages). The endpoint is guarded by the `X-Agent-Token` header matching `KNOWLEDGE_AGENT_TOKEN` and rejects everything when that variable is unset, so nothing is ingested unless you explicitly configure the token and point a client at it. Ingestion is idempotent per `conv_id`: re-posting a conversation is counted as a duplicate and changes nothing.

When vera-api is configured, Pulse and the other ambient surfaces continue operating independently. The two opt-in surfaces afterward each live inside the feature they drive:

- **Plugins** — the integration store, a tab in **Settings** (⌘,). Each card is one integration: enter URL + key, **Test**, **Save & Enable**. The app writes vera-api's config in the same step. Experimental features (whole-house event modeling, media curation) sit behind their parent integration with an explicit consent sheet — off until consented.
- **Veins** — Pulse's ambient monitors, opened from the **Veins** button in the Pulse header. **Vera ships with none**: a vein is something you build for your own life — a river gauge, a service-status watch, a geopolitics bar, whatever deserves an ambient eye — and your catalog starts empty. Every vein is a schema-validated JSON definition living one file per vein at `/data/veins.d/<kind>.json`, managed through the API (`GET /pulse/veins/schema` serves the contract, `POST /pulse/veins` creates). A vein carries a `pipeline` of blocks (the built-ins `web_search`, `http_fetch`, `ha_state`, `trip_band`, `llm_judge`, `llm_compose`, `situation_cluster`, `present`, plus code-backed blocks capabilities register, plus any Python modules you drop in the data volume's `blocks.d/` — the code extension point for bespoke sources, each calling `vein_engine.register` at import) and a cron `schedule`, and the vein engine runs it: dropping a valid definition file in place is all it takes to have a running ambient monitor, and a definition marked `standing` keeps one always-present card updated in place instead of alerting. Each pipeline vein registers a scheduler job as `vein_<kind>`, `POST /pulse/veins/{kind}/run` fires it on demand (`dry_run=true` returns the would-be cards without posting), and the engine owns quiet discipline: one card per distinct situation (updated, never stacked), a seen-memory so watchers don't re-alert on a standing story (`VEIN_SEEN_DECAY_DAYS`, default 7), and a schedule floor for LLM-bearing pipelines (`VEIN_LLM_FLOOR_MINUTES`, default 30; engine state in `VEIN_ENGINE_DB_PATH`). Per-vein enable/options state lives separately in `/data/veins.json`. The Veins pane shows only what this deployment can actually run: a vein whose definition requires an integration appears once that integration is connected (`GET /pulse/veins/catalog` returns exposed veins, `?all=true` adds the requirement-unmet ones for the pane's Add-a-vein browse sheet), and removing the integration hides the vein again while keeping its settings. Veins you author yourself always show, whatever their requirements. You don't have to write definitions by hand: `POST /pulse/veins/builder/turn` runs the authoring conversation against whatever model `VERA_BASE`/`VERA_MODEL` name (describe what you want watched; each turn returns prose plus a schema-validated draft), and `POST /pulse/veins/builder/dry_run` executes an unsaved draft once and returns what would have posted, persisting nothing. With no model configured both endpoints report disabled cleanly. After a vein exists, its Configure sheet can reopen it in the builder to edit the definition in place or delete it outright (`PUT /pulse/veins/{kind}/definition`, `DELETE /pulse/veins/{kind}`), so the whole lifecycle lives in the app.

**Sharing veins.** A vein is a file, so it travels. Export one from its detail sheet (or `GET /pulse/veins/{kind}/export`) and you get a `<kind>.vein.json` with deployment specifics stripped: provider URLs, env-seeded option defaults, and any secret-shaped strings are cleared, so the file is safe to hand to anyone. Import one from the Add-a-vein sheet (or `POST /pulse/veins/import`): it validates against the schema, re-resolves requirements on your deployment, warns about anything unmet or any pipeline block this build lacks (the vein simply cannot enable until it exists), and lands the vein **disabled**. Review it, then enable it exactly like a vein you built yourself. A file from a newer deployment format is refused with a clear message rather than imported half-understood.

Both are UI over vera-api's API — headless deployments can do everything with `curl`.

## 4. Integrations, one by one

Each integration unlocks its capability when its test passes; each degrades to "off" when absent. All are configurable from the integration store or `.env`:

| Integration | Unlocks | Notes |
|---|---|---|
| Home Assistant | Live home state in chat and Pulse, confirm-gated device actuation, the `ha_state` vein block | Use an IP for the URL, not `.local` — containers can't resolve mDNS. Long-lived access token. |
| Grocy | Kitchen inventory + expiry awareness, shopping list | Pairs with Mealie: recipe suggestions from expiring inventory unlock when both are on |
| Mealie | Recipe import, browse, classification | See Grocy pairing |
| Overseerr | Media requests from chat, availability checks; the media-curation blocks for a weekly digest vein (experimental, consent-gated) | |
| Unraid | Confirm-gated container updates, host actuation, update digests | Official Unraid API (GraphQL) with an API key |
| SearXNG | Web search for chat, research, Pulse, watcher veins | Strongly recommended; run it next to vera-api |
| Embeddings | Pulse novelty ranking and the duplicate-finding floor, profile-graph node embeddings for dedup-merge | Any OpenAI-compatible `POST {base}/v1/embeddings` endpoint; the model id is only needed for multi-model servers (llama-swap, hosted APIs). The LLM server can serve this too |
| Vision review | Reviews generated Pulse cover art and permits one retry | Any OpenAI-compatible vision-capable endpoint, including the primary-model endpoint when that model accepts images. Configure its base URL and model, then promote Pulse's visual-review workflow draft. |
| Apple Reminders | Reminders lists read/write from chat, shared lists included | URL of the `vera-reminders` bridge (see satellite services below) |

## 5. Satellite services (all optional)

These are **documented HTTP contracts** with reference implementations in this repo. The references are MLX-based (Apple Silicon), but anything that implements the contract fills the slot:

| Slot | Contract | Reference |
|---|---|---|
| Image gen | OpenAI Images API: `POST {base}/v1/images/generations` | `services/vera-image` — serves the standard contract out of the box; `IMAGE_PROTOCOL=vera` adds deterministic seeds + the vision pause/resume extension |
| Vision | OpenAI chat completions with `image_url` content parts | Any MLX/vLLM-served VLM; see `services/vera-vision` for the launchd template |
| Coder | OpenAI `/v1` with tool calling (`DREAM_TOOL_PROTOCOL=hermes` for servers that pass model text through untouched) | `services/vera-coder` |
| Voice | Wyoming protocol (ASR + TTS) plus a small batch HTTP API | `services/vera-voice`; install with `scripts/deploy-vera-voice.sh` |
| Reminders | Small HTTP API over EventKit: `/health`, `/lists`, `/reminders` | `services/vera-reminders`; install with `scripts/deploy-vera-reminders.sh` |

Reminders reaches EventKit, Apple's only supported door into Reminders, which must run
on a **Mac signed into the iCloud account whose lists Vera should see** — it sees shared
lists, so items added by Siri on any household device appear and Vera's writes sync back
to everyone.

**If you run the Vera Mac app, native chat does not need this service.** Open Settings,
Tools and enable **Apple Reminders**. The native permission prompt appears, and standard
OpenAI tool calls then reach EventKit directly inside the app. The separate Apple
Reminders switch in Settings, Plugins controls the optional vera-api bridge wiring and
does not expose the native chat schema. This path does not need vera-api and runs only for
an explicit chat ask.

`services/vera-reminders` remains the headless reference for deployments with no Mac
app. Run `scripts/deploy-vera-reminders.sh` on a signed-in Mac, approve the one-time
prompt, then enable the Apple Reminders integration with the bridge URL.

Every satellite env var (models, ports, voices, paths) is documented in `.env.example`'s
companion-services section; voice installs with one command (`scripts/deploy-vera-voice.sh` —
runtime copy-out, both venvs, launchd agents), and the image/vision services ship launchd
templates installed via `scripts/install-launchd.sh`.

## 6. The scheduler

vera-api runs all recurring work itself — no external cron. Defaults:

| Job | Default | Gated on |
|---|---|---|
| Pulse briefing | daily 5:00 | — (core; needs your LLM) |
| Home modeling (3 nightly jobs) | 2:00–3:30 | Home Assistant's home-modeling consent |
| Knowledge grooming | daily 4:00 | `KNOWLEDGE_GROOM_ENABLED` |
| Vein runs (`vein_<kind>`) | each definition's `schedule` | that vein's enable state |

Pipeline veins register their jobs dynamically — one per definition, appearing and disappearing with the definition file — and the standard override convention applies (`SCHEDULE_VEIN_<KIND>`, `SCHEDULE_VEIN_<KIND>_ENABLED`).

With home-modeling consent on, the capture stream also tees every numeric `sensor.*` reading into a dedicated series store (`SERIES_DB_PATH`, default `/data/series.db`) retained for `SERIES_RETAIN_DAYS` (default 365) — the substrate household forecasting reads. Inspect it at `GET /home/series` (entities + counts) and `GET /home/series/{entity_id}` (raw points); on first init it backfills from the existing event log. With capture off it stays empty and both endpoints return empty cleanly.

A gated job never fires while its gate is closed — on a fresh install, nothing is monitored until its vein is enabled or its feature is consented to. The app's **Agentic** tab renders all of this as a canvas: every flow as a node connected to the surface it feeds (the Pulse feed, the veins, memory, actions), with live status and running-state. The topology comes from `GET /agentic/graph`, a server-declared manifest, so a new capability appears on the canvas without an app update. Schedules can be pinned with `SCHEDULE_<JOB>` / `SCHEDULE_<JOB>_ENABLED` env overrides. A gated job reports *why* it is gated instead of running.

Clicking any flow opens it in the workflow editor, and the sidebar switches to the node library served by the API's workflow catalog. Every flow is served as a workflow definition with a Schedule trigger at the head reflecting its real schedule: scheduled code-backed flows project their steps, veins project one step per pipeline block, and Pulse serves its stored graph. In an editable flow like Pulse, drag nodes into the main workflow canvas (dropping one onto a wire splices it into the path), drag from a node's output port to another's input port to connect them, hover a wire for an insert shortcut, and pan or zoom the canvas to work with larger graphs. Select a node to configure it through fields rendered from its served schema, and use an explicit draft promotion when the graph is ready. Code-backed flows carry a locked profile: the graph reads and inspects like any other, structural editing is absent and rejected server-side, and the settings each node's schema declares (starting with the trigger's schedule) still round-trip through the same draft and promote path. Promotion applies a changed schedule to the built-in scheduler, which stays the thing that actually fires runs. The server validates every save and promotion and its message appears in the editor when a graph is rejected. Editing a draft never changes a published workflow.

A Run toggle on the same canvas overlays the latest recorded run, per node state, output counts, and duration, and selecting a node shows its recorded input, output, timing, and any error in place of the config fields.

Everything autonomous is auditable in one place: `GET /agentic/activity?hours=24` returns a normalized, newest-first feed merging scheduled job runs and the action audit log. The app renders it as the **Activity** pane of the Agentic tab, refreshed every 30 seconds, and recent events animate along their edges on the canvas. A missing backing store contributes nothing instead of erroring, so the feed works on any subset of the stack.

## 7. Verifying the install

1. `curl localhost:8089/health` — vera-api is up.
2. The startup config report lists every endpoint you configured (and flags anything deprecated or missing).
3. Chat in the app — ask something that needs a tool (e.g. a web search) and confirm the tool fires.
4. Trigger a Pulse run from the app (or `POST /pulse/run`) and watch cards arrive.
5. Create a vein (the in-app builder or `POST /pulse/veins`), enable it, and confirm its chip appears; its job in Agentic shows the next run time.

When something doesn't work, check the config report and `docker compose logs vera-api` first.
