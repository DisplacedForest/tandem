# Household assistant messaging

The household gateway lets separately consenting people deliberately share a message or summary between their assistants. It stores only the text submitted for sharing. It does not read conversations, private memory, household profiles, or other Vera databases. The service contains no seeded people.

The capability is part of the existing Vera API. `/household/mcp` returns 503 until a host application explicitly supplies `app.state.household_gateway`. The default application never creates credentials, enrolls members, stores signing secrets, starts delivery, or opens another port.

## Local integration

`routers.household_store.Store(path)` owns a separate SQLite database. Use a private directory on local storage, not a network share. The database is created mode 0600. Backups need the same protection because an enabled subscription holds callback signing material. SQLite transactions commit messages and their outbox records together.

`Gateway(store, verify, events=None)` accepts a verifier callable. It receives a bearer token and must return a stable opaque principal only after validating the credential's signature, issuer, audience, expiration, revocation, and permitted gateway access. Never use a claimed username, identity header, or request argument as this result. There is no permissive fallback. Enrollment is a privileged store operation outside the MCP tool surface and must follow the member's individual consent. Do not reuse somebody else's account credentials.

For an approved callback deployment, construct `Events(store, PublicHTTPS(approved_hosts))` and supply it to `Gateway`. `approved_hosts` must contain only exact callback hostnames approved for this connection. The transport validates public destination addresses on every connection, pins the selected address, preserves TLS hostname validation, and does not follow redirects. DNS has a five-second wait limit and two resolver slots; network IO has a ten-second total deadline. A permanently stuck system resolver can consume a slot until process restart, but cannot create unlimited resolver workers.

An enabled host should supervise `Gateway.run_events()` within its lifespan and await cancellation at shutdown. This worker is deliberately not started by the default Vera application. It handles one durable outbox item per second. Production wiring, OAuth discovery, consent UI, secret management, retention policy, and private connector registration are setup work still required before household use. The callable verifier is an integration boundary, not a shipped OAuth authorization server.

## Pairing and sharing

1. Each owner is enrolled separately after consenting. Each assistant authenticates as that owner.
2. `pair_offer` chooses an enrolled peer and explicit `message` and/or `summary` scopes. `pairs_list` lets each owner inspect the peer and scopes. The offer has no sharing effect until the invited owner accepts through `pair_consent`.
3. `message_share` submits only the owner-approved text, with a stable idempotency key. Reusing that key with different content fails. A reply supplies the parent message ID. There is one reply per parent per sender, at most four reply hops, and 60 new messages per owner per hour. These bounds do not replace assistant-side approval.
4. `inbox_read` returns only the authenticated recipient's messages. Continue pagination with the last record's integer `cursor` in `after`. This cursor orders records even when timestamps match.
5. `message_ack` records delivery, then processing. Processing acknowledgment is a recipient assertion and must only follow completed work. `message_status` separates those assertions from callback HTTP receipts.
6. Either owner can revoke a pair. Revocation cancels pending events and hides the pair's messages from both participants. It cannot erase copies already received or recall a network request already in flight. A revoked pair cannot be revived; make a new offer for new consent. Member disable blocks subsequent authenticated requests and sharing.

Message bodies are untrusted third-party data. Receiving a message does not authorize tools, replies, forwarding, memory writes, or account changes. An assistant must consult its own owner's instructions. The gateway never executes message text, invokes an LLM, or reads or merges private histories. It cannot prove human intent from text alone, so client-side confirmation remains essential.

## Events and evidence

The adapter supports MCP version `2026-07-28`, `server/discover`, tools, and the three event methods. Events carry only a message ID; clients fetch authorized inbox content. Signing, challenge verification, subscription refresh, rotation and expiration are implemented. No replay cursor is advertised. The inbox remains the recovery path for messages missed while unsubscribed.

Transient delivery failures retry at 30, 60, 120, then 240 seconds, up to five attempts. The event ID and occurrence time remain stable. Claims commit before IO, so a crashed attempt consumes its retry budget. A 410 disables its subscription; 413 and other permanent failures are terminal. Failed records are retained for diagnosis, with no automatic redrive. Unsubscribe is idempotent and wins over verification already in flight.

The OpenAI documentation describes webhook receipt as asynchronous acceptance, with client processing requiring separate observation. It also requires per-user authentication and connection through public HTTPS or Secure MCP Tunnel. See [MCP Events](https://developers.openai.com/plugins/build/mcp-events), [connection setup](https://developers.openai.com/plugins/deploy/connect-chatgpt), and [authentication](https://developers.openai.com/plugins/build/auth). These sources were checked on October 9, 2026.

Acceptance has distinct stages: built source, isolated tests, deployed service, remote discovery, callback receipt, and an observed response in each consenting account. Passing an earlier stage never proves a later one. The current implementation is a local integration candidate, not a configured cross-account service.

## Verification

Run `mise run api-test` for the complete API suite. The focused tests are `tests/test_household.py` and `tests/test_household_mcp.py`. They use temporary databases, synthetic principals and signing fixtures, and fake callbacks. The store and event tests also run with Python's standard library alone:

```sh
cd services/vera-api
python3 -m unittest discover -s tests -p test_household.py -v
```

No real account, external callback, or production state is needed. Test credentials must never be used in a live deployment.
