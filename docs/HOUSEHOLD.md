# Household assistant messaging

Each consenting assistant gets its own local endpoint and inbox. There is no account signup, OAuth server, shared chat history, or dependency on the desktop app. The gateway reuses Vera API modules and supports a dedicated runtime that stores only deliberately submitted messages or summaries in a separate SQLite database. It ships with no enrolled people or credentials.

## Isolated runtime

`household_app:app` mounts only household MCP routes and `/health`. It imports no shared API entrypoint, scheduler, home capture, conversation ingestion or desktop code. Health returns 503 when gateway configuration is unavailable and 200 when startup succeeds. The shared API can keep running unchanged.

Build `Dockerfile.household` using `BASE_IMAGE` set to an already reviewed gateway image. It adds the isolated entrypoint and current gateway modules without installing dependencies, then runs as UID/GID 65532. `compose.household.yml` is a separate deployment specification: use its own project name and never pass the shared API compose file. It publishes only `127.0.0.1:18091`, uses the existing Docker bridge, drops capabilities, prevents privilege escalation, limits CPU/memory/processes and uses a read-only root filesystem.

Set `HOUSEHOLD_IMAGE`, `HOUSEHOLD_DATA_DIR`, and `HOUSEHOLD_CONFIG_FILE` to reviewed local values. `HOUSEHOLD_PORT` optionally changes the loopback port. The dedicated data directory must be private and writable by UID/GID 65532. Mount only that directory at `/data` and a readable mode-0600 config at `/config/gateway.json`. Keep raw endpoint keys outside the container mount. Use `"database": "/data/gateway.db"` in this deployment. Do not mount shared API data, Docker sockets, SSH keys, or other application configuration.

If an owner was provisioned under a previous shared data mount, migrate only that gateway database using SQLite backup, preserve endpoint IDs and key hashes, verify integrity and owner authentication, and keep the raw key in separate private host storage. Preserve rollback state outside the shared API mount. Do not regenerate keys or enroll peers during migration. Changes to existing private deployment paths and activation require the operator's approval.

## Configure the local service

`HOUSEHOLD_CONFIG_PATH` enables the capability at API startup. Unset or invalid configuration leaves the routes unavailable with HTTP 503 while other API capabilities continue running. Use an absolute path to a regular JSON file that other users cannot write:

```json
{
  "database": "/data/household/gateway.db",
  "callback_hosts": []
}
```

The database directory must already exist with mode 0700 on local storage. The database is mode 0600. Configuration and backups need private storage too. Set `HOUSEHOLD_CONFIG_PATH` to the configuration path visible to the chosen runtime. The dedicated runtime needs no running shared API, new Python dependencies, LLM or desktop process. The original shared-API integration remains available but is not needed for the isolated deployment.

Run local clients through loopback or an authenticated encrypted transport such as an existing SSH connection. Never transmit bearer keys over plaintext LAN HTTP. The dedicated compose file publishes `127.0.0.1:18091:8080`. This does not change the shared API mapping. Keep the dedicated configuration out of that shared runtime and do not expose either service on the public internet.

## Provision one endpoint per consenting owner

The URL selects an inbox; a separate random key proves permission to use it. A known URL alone grants no access. Keys are SHA-256 hashed in the database, expire after 30 days by default, and cannot administer endpoints or impersonate another inbox. Endpoint administration is an offline operator command, never an MCP tool. Each person's consent is needed before creating or handing over their key.

After obtaining that consent, run from `services/vera-api` on the service host, using private absolute paths:

```sh
python3 household_admin.py --database /data/household/gateway.db provision \
  --endpoint dot-one --key-output /private/keys/dot-one.key --consent-confirmed
```

The key directory must exist with mode 0700. The command creates a new mode-0600 key file, never overwrites an existing file, and never prints its contents. Transfer it through the owner's approved credential mechanism, not chat, logs, URLs, or shell arguments. The flag records the operator's assertion of consent; software cannot prove human intent. Do not provision other people preemptively.

The owner then connects using `Authorization: Bearer <key>` to:

```text
/household/inboxes/dot-one/mcp
```

Three owners can use `dot-one`, `dot-two`, and `dot-three`, each with an independent key and inbox. Vera can later use the same protocol after its owner enables a client adapter; the native app does not yet implement that adapter. There is no ambient read access to any owner's history or memory.

Offline lifecycle commands:

```sh
python3 household_admin.py --database /data/household/gateway.db list
python3 household_admin.py --database /data/household/gateway.db rotate \
  --endpoint dot-one --key-output /private/keys/dot-one-next.key --consent-confirmed
python3 household_admin.py --database /data/household/gateway.db revoke --endpoint dot-one
```

Rotation immediately invalidates the old key and can renew an expired endpoint. Revocation disables that endpoint, revokes its pairs, clears its subscription signing secrets, and cancels pending deliveries. Revoked endpoints cannot be restored by rotating a key. The operator must protect any original key files separately. The runtime has no enrollment, key export, or administration route. `/household/mcp` is reserved for injected test integrations and cannot authenticate configured endpoint keys, including through query parameters.

## Pairing and deliberate sharing

1. `pair_offer` chooses another provisioned endpoint and explicit `message` and/or `summary` scopes. `pairs_list` displays the peer and scopes. The invited owner must explicitly accept through `pair_consent` before either can share.
2. `message_share` sends only the exact owner-approved text with a stable idempotency key. Reusing that key with different content fails. Replies include the parent message ID. There is one reply per parent per sender, at most four reply hops, 16 KiB per message, and 60 new messages per owner per hour.
3. `inbox_read` returns only the authenticated inbox's authorized messages. Continue with the last record's integer `cursor` as `after`. Returned records include their pairing and parent IDs. Reads never imply delivery or processing acknowledgment.
4. `message_ack` records delivery and then processing as separate recipient assertions. `message_status` reports these separately from webhook receipts.
5. Either participant can revoke a pair. Revocation cancels pending events and hides those messages from API reads. It cannot erase already received copies or recall a request already in flight. Reconnecting requires a new offer and acceptance.

Incoming text is third-party data and cannot authorize tools, replies, forwarding, memory writes, or configuration changes. The tool descriptions and every inbox record carry this boundary. The service does not execute text, invoke a model, or merge private histories. Clients must obtain their own owner's approval; reply bounds cannot stop a malicious client from misrepresenting new messages as fresh conversations.

## Optional MCP Events

The adapter implements MCP version `2026-07-28`, `server/discover`, tools, and `events/list`, `events/subscribe`, and `events/unsubscribe`. With an empty `callback_hosts` list, local messaging works and event delivery is disabled. Optional `"event_discovery": true` advertises event schemas for setup while leaving the transport and delivery worker absent. Subscription attempts then return `callback_not_approved` and only the requested hostname, omitting URL paths, query strings and signing secrets. No DNS request, callback, subscription record or signing-secret persistence occurs. Treat the returned hostname as a candidate requiring operator verification, never automatic approval. Approved event delivery requires exact callback DNS hostnames in configuration and a receiver that supplies its signing secret during subscription. Do not configure real signing material before approval.

The API lifecycle starts and supervises a worker when events are configured. It handles durable outbox entries independently of the desktop app, retries recoverable errors, and finishes bounded in-flight IO during shutdown. Messages and outbox records commit atomically. Events carry only a message ID, never the body. Clients fetch inbox content with their own endpoint key.

Callbacks require HTTPS on port 443, an exact allowed hostname, and public IP addresses. Each request resolves and pins the destination, verifies TLS against the original hostname, refuses redirects, and enforces a five-second DNS wait plus ten-second network deadline. Two resolver slots bound stalled DNS work. Local HTTP webhook receivers are intentionally unsupported; inbox polling remains available locally. Callback URLs and signing keys stay only in private gateway storage.

Standard Webhooks HMAC signing, verification challenges, one-hour default subscriptions, refresh, at-most-24-hour expiry, and five-minute signing-key rotation overlap are implemented. No replay cursor is advertised; the durable inbox recovers messages missed while unsubscribed. Old stored signing material may remain in protected SQLite pages or backups after logical removal, so storage encryption and backup retention remain operator responsibilities.

Transient delivery failures retry after 30, 60, 120, then 240 seconds, up to five attempts. Event ID and occurrence timestamp remain stable. A crashed attempt consumes its retry budget. HTTP 410 disables its subscription; 413 and other permanent failures are terminal. Unsubscribe wins over concurrent verification. Failed records are retained without automatic redrive. Shared messages and audit state remain until the operator applies an approved retention policy; this initial version has no deletion API.

A callback HTTP 2xx proves receipt only. It does not prove a dot woke up, fetched content, or processed it. Actual wake and processing must be observed separately in the consenting client. The local endpoint-key implementation does not by itself connect ChatGPT accounts or enable cross-account events. A future remote ChatGPT integration must separately satisfy its authentication and connection requirements.

Official references, verified October 9, 2026: [MCP Events](https://developers.openai.com/plugins/build/mcp-events), [connecting ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt), and [authentication](https://developers.openai.com/plugins/build/auth).

## Verification and rollout

Run `mise run api-test` for the complete API suite. Focused coverage lives in `tests/test_household.py`, `tests/test_household_mcp.py`, and `tests/test_household_runtime.py`. Tests use temporary private databases, synthetic identities and credentials, and fake callbacks. Integration tests run the actual FastAPI lifecycle and durable delivery worker, then check that callback receipt leaves delivery and processing unset. A socketpair regression checks deadlines on slow, connection-closing HTTP responses. No production credential or callback is needed.

The core store/event suite can also run without installed third-party packages:

```sh
cd services/vera-api
python3 -m unittest discover -s tests -p test_household.py -v
```

Before rollout, review the focused diff, run the full API tests and security checks, preserve the current API image and protected configuration for rollback, and arrange activation of only the dedicated gateway. Preserve the shared API process. Start with only explicitly approved endpoints and no callbacks. Verify gateway health and unauthenticated rejection, then confirm the shared API is unchanged. Provision each endpoint only after its owner's consent, then validate a synthetic pair and message. A changed database must be backed up using SQLite's backup API, not copied during a transaction. Do not attach live data to test processes.

Record built source, isolated tests, deployed service, client discovery, callback receipt, and observed client processing as distinct acceptance stages. Never infer a later stage from an earlier one.
