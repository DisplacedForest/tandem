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

Three dots can use `/household/inboxes/dot-one/mcp`, `/household/inboxes/dot-two/mcp`, and `/household/inboxes/dot-three/mcp`, each with a separate inbox. These are local identities, not user accounts. Only provision endpoints whose owners have opted in. The URL selects an inbox; a separate random key proves permission to use it. A known URL alone grants no access. Keys are SHA-256 hashed in the database, expire after 30 days by default, and cannot administer endpoints or impersonate another inbox. Endpoint administration is an offline operator command, never an MCP tool. Each person's consent is needed before creating or handing over their key.

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

For ChatGPT, a private Secure MCP Tunnel can carry one owner's local endpoint authorization header. Keep that tunnel and plugin restricted to that owner. A second person needs a separately consented endpoint, separate tunnel, and verified narrow tunnel access. Never share a static owner-authorized tunnel as another person's inbox. OpenAI documents per-tunnel User permissions, but cross-personal-account sharing eligibility must be checked before offering household invitations. Public plugin distribution does not support Secure MCP Tunnels.

`household_onboarding.py` renders a small, dependency-free setup page. Pass both `--plugin-url` and `--app-id`, using the exact plugin page and registered App ID verified for that recipient. The URL must be `https://chatgpt.com/plugins/plugin_` followed by that App ID. The exact plugin URL, which contains that App ID, is included in the short copied request. The bundled skill resolves the assigned native event source before subscribing. A missing or inaccessible source stops setup; similarly named apps are never substituted. With neither value, the page explains that setup is unavailable and offers no copyable request or install action. Partial or mismatched values are rejected. The LAN guidance URL is not an MCP subscription endpoint; ChatGPT subscribes through the installed plugin connection. The page creates no identity, credentials, invitation or consent record. Its only script copies a visible request after a user click; it makes no network request and stores no browser state. The recipient reviews and sends that request in their own ChatGPT conversation. Page text, a copied draft, and a clicked link do not grant authority or prove consent.

The short request invokes the bundled setup skill, which covers native installation/connection approval, an authenticated inbox read, a persistent event subscription, one fixed synthetic setup check, actual event wake/fetch, separate delivery/processing acknowledgments, and subsequent subscription renewal. Reuse an existing matching subscription. Installation alone does not subscribe a dot, and no supported install-plus-subscribe deep link is assumed. If the setup tool or personal connection is unavailable, leave the corresponding stage pending. Pairing and real sharing remain separate approvals. No recipient terminal commands or key copying are required.

OpenAI also supports a packaged setup skill through `extensions.com.openai.onboardingSkill`. After installing the plugin, the user invokes setup in a native conversation. That skill can guide subscription and the synthetic check, but it cannot create access or treat installation alone as consent to real sharing. The visible setup request remains a fallback. Installation, running native setup, subscription acceptance and the actual test are separate steps; none implies the next has succeeded. See [plugin onboarding](https://developers.openai.com/plugins/build/plugins#add-an-onboarding-skill).

After a consenting dot’s private connection is registered and its App ID is verified in native settings, package it from `services/vera-api`:

```sh
python3 household_plugin.py --app-id "$HOUSEHOLD_REGISTERED_APP_ID" --output /private/packages/inbox.zip
```

The App ID starts with `asdk_app_`; it is not the plugin page ID. The packager accepts no endpoint key and creates no connection or credential. Its ZIP contains a root manifest, a mapping to exactly that registered app, and the bundled setup skill. Existing output files are never overwritten. For an update, first download the existing plugin ZIP through its native menu and inspect its manifest name and registered app mapping. Pass that exact internal name as `--plugin-name` and an increased three-part package `--version`; the display name is not the internal name. Preserve the same verified App ID. An identity mismatch is rejected by the native uploader. Upload this reviewed package through the existing private plugin’s native update flow, verify it preserves the intended app connection, and test native setup. An existing installation may show Try in chat instead of Run setup; return to the existing dot conversation and invoke the bundled skill with the provided short request. Use Work only when that is the surface managing that dot's inbox notifications. Do not publish an owner-mapped ZIP as somebody else’s inbox.

The recipient instructions are three steps: open the personal link, say “Set up my inbox” in the conversation that manages the dot's notifications, and wait for the test message. The setup page contains the exact personal plugin link and a short request, with no recipient ZIP upload, server address or gateway signup. If the bundled skill cannot be loaded, setup stops instead of improvising a replacement. A fresh browser Work conversation was observed to read the assigned inbox but could not locate an existing Codex dot automation. Keep setup in the owning dot context and do not create a replacement subscription to work around that lookup boundary. The full flow is: open their verified private plugin link, approve native installation and connection, run setup in their own dot, approve incoming notifications and one synthetic test when needed, then wait for the event-triggered fetch and processing confirmation. Setup reuses a matching safe subscription, preserves existing pairings and does not create other endpoints. A connection that has not yet been provisioned remains an operator setup boundary; a static page cannot complete that step. Native package installation must still be tested in both a fresh conversation and an existing conversation before calling the recipient flow ready.

`inbox_setup_check` requires the connected owner's direct request and an active, unexpired event subscription. It creates only a fixed synthetic message addressed to that same owner, with no new identity, endpoint, credential or pairing. A caller supplies a stable `dedup` value; retries return the same message ID. Fresh checks are limited to one per hour per owner. The standard durable outbox and acknowledgment methods handle the check, and revocation stops delivery. The setup call never claims processing succeeded.

A private tunnel must be associated with the intended OpenAI organization/workspace, and its permissions are separate from plugin installation. A tunnel that injects one owner's endpoint key cannot be shared as another person's inbox. Personal custom plugin creation and eligible workspace plugin sharing are distinct routes; verify the recipient's actual access before publishing their connection link. Public plugin distribution requires public HTTPS and is outside a private-only deployment. A static LAN page cannot authenticate another ChatGPT user or issue their credentials. No website sign-in or gateway account system is needed. The operator maps each consenting dot to its own endpoint; ChatGPT installation and tunnel access remain separate platform steps.

```sh
python3 household_onboarding.py --plugin-url "$RECIPIENT_PLUGIN_URL" --app-id "$HOUSEHOLD_REGISTERED_APP_ID" --output /private/setup/index.html
```

Preview the generated page on loopback first. Serving it on a LAN interface requires a separate approved listener scope. Keep keys out of HTML and URLs, and never substitute the operator's plugin link for an unprovisioned recipient. An event wake remains a separate acceptance test after the inbox read succeeds.

1. `pair_offer` chooses another provisioned endpoint and explicit `message` and/or `summary` scopes. `pairs_list` displays the peer and scopes. The invited owner must explicitly accept through `pair_consent` before either can share.
2. `message_share` sends only the exact owner-approved text with a stable idempotency key. Reusing that key with different content fails. Replies include the parent message ID. There is one reply per parent per sender, at most four reply hops, 16 KiB per message, and 60 new messages per owner per hour.
3. `inbox_read` returns only the authenticated inbox's authorized messages. Continue with the last record's integer `cursor` as `after`. Returned records include their pairing and parent IDs. Reads never imply delivery or processing acknowledgment.
4. `message_ack` records delivery and then processing as separate recipient assertions. `message_status` reports these separately from webhook receipts.
5. Either participant can revoke a pair. Revocation cancels pending events and hides those messages from API reads. It cannot erase already received copies or recall a request already in flight. Reconnecting requires a new offer and acceptance.

Incoming text is third-party data and cannot authorize tools, replies, forwarding, memory writes, or configuration changes. The tool descriptions and every inbox record carry this boundary. The service does not execute text, invoke a model, or merge private histories. Clients must obtain their own owner's approval; reply bounds cannot stop a malicious client from misrepresenting new messages as fresh conversations.

## Optional MCP Events

The adapter implements MCP version `2026-07-28`, `server/discover`, tools, and `events/list`, `events/subscribe`, and `events/unsubscribe`. Object-valued request `_meta` is accepted and discarded; it cannot select an identity or grant authority. With an empty `callback_hosts` list, local messaging works and event delivery is disabled. Optional `"event_discovery": true` advertises event schemas for setup while leaving the transport and delivery worker absent. Subscription attempts then return `callback_not_approved` and only the requested hostname, omitting URL paths, query strings and signing secrets. The hostname alone is logged for operator setup diagnostics. No DNS request, callback, subscription record or signing-secret persistence occurs. Treat the returned hostname as a candidate requiring operator verification, never automatic approval. Approved event delivery requires exact callback DNS hostnames in configuration and a receiver that supplies its signing secret during subscription. Do not configure real signing material before approval.

The API lifecycle starts and supervises a worker when events are configured. It handles durable outbox entries independently of the desktop app, retries recoverable errors, and finishes bounded in-flight IO during shutdown. Messages and outbox records commit atomically. Events carry only a message ID, never the body. Clients fetch inbox content with their own endpoint key.

Callbacks require HTTPS on port 443, an exact allowed hostname, and public IP addresses. Each request resolves and pins the destination, verifies TLS against the original hostname, refuses redirects, and enforces a five-second DNS wait plus ten-second network deadline. Two resolver slots bound stalled DNS work. Local HTTP webhook receivers are intentionally unsupported; inbox polling remains available locally. Callback URLs and signing keys stay only in private gateway storage.

Standard Webhooks HMAC signing, verification challenges, one-hour default subscriptions, refresh, at-most-24-hour expiry, and five-minute signing-key rotation overlap are implemented. No replay cursor is advertised; the durable inbox recovers messages missed while unsubscribed. Old stored signing material may remain in protected SQLite pages or backups after logical removal, so storage encryption and backup retention remain operator responsibilities.

Transient delivery failures retry after 30, 60, 120, then 240 seconds, up to five attempts. Event ID and occurrence timestamp remain stable. A crashed attempt consumes its retry budget. HTTP 410 disables its subscription; 413 and other permanent failures are terminal. Unsubscribe wins over concurrent verification. Failed records are retained without automatic redrive. Shared messages and audit state remain until the operator applies an approved retention policy; this initial version has no deletion API.

A callback HTTP 2xx proves receipt only. It does not prove a dot woke up, fetched content, or processed it. Actual wake and processing must be observed separately in the consenting client. The local endpoint-key implementation does not by itself connect ChatGPT accounts or enable cross-account events. A future remote ChatGPT integration must separately satisfy its authentication and connection requirements.

Official references, verified October 9, 2026: [MCP Events](https://developers.openai.com/plugins/build/mcp-events), [connecting ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt), and [authentication](https://developers.openai.com/plugins/build/auth).

## Verification and rollout

Run `mise run api-test` for the complete API suite. Focused coverage lives in `tests/test_household_gateway.py`, `tests/test_household_mcp.py`, and `tests/test_household_runtime.py`. Tests use temporary private databases, synthetic identities and credentials, and fake callbacks. Integration tests run the actual FastAPI lifecycle and durable delivery worker, then check that callback receipt leaves delivery and processing unset. A socketpair regression checks deadlines on slow, connection-closing HTTP responses. No production credential or callback is needed.

The core store/event suite can also run without installed third-party packages:

```sh
cd services/vera-api
python3 -m unittest discover -s tests -p test_household_gateway.py -v
```

Before rollout, review the focused diff, run the full API tests and security checks, preserve the current API image and protected configuration for rollback, and arrange activation of only the dedicated gateway. Preserve the shared API process. Start with only explicitly approved endpoints and no callbacks. Verify gateway health and unauthenticated rejection, then confirm the shared API is unchanged. Provision each endpoint only after its owner's consent, then validate a synthetic pair and message. A changed database must be backed up using SQLite's backup API, not copied during a transaction. Do not attach live data to test processes.

Record built source, isolated tests, deployed service, client discovery, callback receipt, and observed client processing as distinct acceptance stages. Never infer a later stage from an earlier one.

## Direct HTTPS connection with OAuth

An optional OAuth adapter lets every household member add the same public HTTPS
MCP URL to ChatGPT. It needs no household account signup and no recipient-managed
network connection. Set `HOUSEHOLD_PUBLIC_ORIGIN` to the canonical HTTPS origin
without a trailing slash. The MCP address is that origin plus `/mcp`. Leave the
variable unset to disable all public OAuth routes. Existing private inbox URLs and
keys keep their existing behavior.

Publish only `/mcp`, `/oauth/authorize`, `/oauth/token`, `/oauth/register`,
`/oauth/revoke`, `/.well-known/oauth-authorization-server`,
`/.well-known/oauth-protected-resource`, and
`/.well-known/oauth-protected-resource/mcp`. Keep health, private inbox routes,
configuration, and the database off public ingress. Terminate HTTPS at an approved
reverse proxy and disable request body, authorization header, cookie, and query
logging. OAuth authorization queries contain state and PKCE metadata. Do not log
callback URLs containing authorization codes. No proxy may cache these responses.
The gateway must retain its single worker and existing event worker.

After the member opts in, an administrator provisions their separate inbox with
the existing operator workflow. The administrator then calls
`OAuth(store, public_origin).enroll(endpoint)` locally on the server to issue one
random connection code for that inbox. This operation never exposes the inbox
key. Deliver the result privately to that member, never through a URL or shared
page. A new code replaces previous unused codes for the same inbox. It expires
within ten minutes and can authorize one connection only. There is deliberately
no public enrollment or administration API.

The member adds the canonical MCP URL in ChatGPT, uses OAuth, enters their
connection code on the consent page, and chooses **Connect**. No OpenAI Platform
workspace or tunnel setup is needed. The page grants access to that inbox only;
it does not create a sharing pair, enroll another member, copy private histories,
or subscribe to events. The member must still ask their dot to enable incoming
notifications. Reuse an existing matching subscription. Actual event wake,
message fetch, delivery acknowledgement, and processing acknowledgement remain
separate acceptance checks.

The adapter uses dynamic registration for public clients, the documented ChatGPT
redirect addresses, authorization codes with S256 PKCE, explicit resource and
scope binding, and issuer identification. Enrollment codes, authorization codes,
and tokens are stored as SHA-256 hashes. Browser consent uses a secure HttpOnly
SameSite cookie and matching form token, an exact Origin check, and five attempts
per short-lived session. Request sizes, registration counts, live grants, and
request rates are bounded. Under registration pressure, the oldest unused client
registration is reclaimed. Clients with pending consent, authorization codes, or
existing grants are preserved. A household connection code is a temporary bearer
credential; give it only to its intended member.

Access tokens expire within one hour. Rotating refresh tokens stop at the grant's
30-day lifetime or the inbox's earlier expiry. Reusing a rotated refresh token
revokes that grant. Revocation of either an access or refresh token revokes its
whole grant. Endpoint revocation, expiry, member disablement, or endpoint key
rotation immediately invalidates its OAuth grants and unused enrollment codes.
These checks also apply after a gateway restart. Revoking an OAuth grant prevents
further calls and subscription renewal; use endpoint revocation when event
subscriptions must be canceled immediately too.

Verify discovery, authorization, token refresh, inbox isolation, event delivery,
and revocation from the actual ChatGPT connection before calling a public setup
ready. Passing isolated OAuth tests does not establish cloud reachability or an
actual dot wake. The implementation follows the official
[OpenAI authentication guide](https://developers.openai.com/plugins/build/auth)
and [MCP authorization specification](https://modelcontextprotocol.io/specification/latest/basic/authorization).

Once the public connection is verified, render a shared setup page with the exact
MCP address. It contains no inbox code or private key:

```sh
python services/vera-api/household_onboarding.py \
  --mcp-url "$HOUSEHOLD_PUBLIC_ORIGIN/mcp" \
  --output /tmp/household-connect.html
```

The page links to ChatGPT Plugins, explains the OAuth connection, and includes a
copyable notification setup request with the same MCP address. Publish it only
after verifying that address. The renderer rejects embedded credentials, query
parameters, fragments, and mixed plugin/public destinations.
