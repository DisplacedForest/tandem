# Isolated native transport prototype

This standalone macOS helper tests a credential boundary for the Pi assistant prototype. It is separate from Vera.app, the installed engine, and their task databases. It has no app installation step, listening port, credential export, signing command, or Keychain mutation. Pi can select the helper through an explicit mock-only host adapter. Its live path remains unselected and unapproved.

Run `mise run pi-native-transport-test` from the repository root. It builds the helper, runs injected credential and URLProtocol tests, then exercises private pipes with real child processes, EOF, cancellation, SIGKILL recovery, and blocked output. These tests use synthetic credentials and injected HTTP only. They neither inspect saved settings nor contact OpenRouter.

## Protocol

The trusted host starts `VeraNativeTransport --mock-stdio`, the scripted Pi fixture mode `--mock-pi-stdio`, or, after separate approval, `--live`, followed by exactly four options: `--permit FILE`, `--request-permits DIRECTORY`, `--ledger-root DIRECTORY`, and `--approved-sha256 HASH`. The hash must match the executable bytes. It records which reviewed build the operator selected; it is not a signature or an authentication mechanism. The host owns the private pipe and authorization files. Workers receive neither the permit directory nor unrestricted filesystem tools. A malicious process with the host's user identity is outside this prototype's threat model.

Launch and request permits are nonsecret JSON, regular files owned by the current user with mode 0600 in directories with mode 0700. Use fresh isolated directories. The ledger rejects the live Vera data directory, symlink or hardlinked database files, unsafe sidecars, foreign ownership, and concurrent owners. Preserve the same ledger across experiments. Do not create a fresh ledger to work around an uncertain reservation.

The launch permit contains:

| Field | Accepted value |
| --- | --- |
| `transport` | `mock` or `live`; the executable mode must match, and a ledger cannot mix them |
| `experiment_id`, `reconciliation_id` | Fresh lowercase UUIDs |
| `profile_id` | Exact saved profile UUID spelling |
| `issued_at`, `expires_at` | Unix seconds, issued within five minutes, expires within one hour |
| `prior_test_spend_usd` | Reconciled cumulative Vera test spend as a decimal string |
| `budget_usd`, `max_requests` | At most `"1"` USD and 12 calls |
| `exclusive_test_owner` | `true`, after coordination with every other test owner |
| `budget_scope`, `credential_access` | `vera-tests`, `noninteractive-once` |
| `sessions` | At most two foreground identities and one worker identity, each with `id`, `task_id`, and `role`. For mock permits only, explicit `task_id:null` authorizes one durable first-use binding after request validation |

Each newline-delimited completion is an object with `op: "complete"`, lowercase UUID `request_id`, matching `session_id`, `task_id`, `role`, required `mode` (`assistant` or `focused`), and `messages`. The host separately creates `REQUEST_UUID.json` with `request_id`, `experiment_id`, and `input_sha256`, the SHA-256 of sorted-key UTF-8 request JSON with no extra whitespace or escaped slashes. The helper verifies the full request against this permit before credential access. Task identity and mode bind atomically on first use and cannot change across races or restart. Focused foreground requests cannot send or receive delegation calls. Callers should restrict envelope numbers to integers and use plain text messages to keep canonicalization unambiguous.

Messages use `system` or `user` with text content, `assistant` with typed `text` and `toolCall` blocks, or `toolResult` with a matching `toolCallId`. Results may include a matching `toolName` and boolean `isError`. Images, unknown fields, unpaired results, reused call IDs, foreign identities, and arbitrary tool schemas are rejected. Foreground can request `delegate`; workers can request `read_file`, `write_file`, or `check_python` only for the disposable `sum.py` fixture. Python still owns execution, approvals, and effect receipts.

Responses contain `request_id`, `ok`, and either typed `content` plus `usage`, or a fixed error code. The helper never returns raw provider error bodies, headers, or credentials. Send `{"op":"cancel","request_id":"..."}` to cancel an active request. EOF cancels all requests. Undrained stdout causes bounded process exit; the host must treat a missing or partial response as unconfirmed, never automatically resend it with a new identity.

## Provider and durable accounting

The model is fixed to `qwen/qwen3.8-flash`; all requests use `https://openrouter.ai/api/v1/`. URLSession has no cookies, cache, credential storage, redirects, or paid retries. A completion has a 30-second total deadline, at most 256 output tokens, and at most 8192 serialized input bytes including tool schemas. Forecasting reserves 16384 input tokens plus 256 output tokens at current advertised prices. Mandatory reasoning, aliases, unknown billable prices, or unsupported parameters stop execution. Provider routing disables fallback, requires parameters, and includes price ceilings.

One foreground and one worker request may run together. Each session allows at most four calls and eight returned tool calls. A FULL-synchronous SQLite ledger with an exclusive process lock reserves spend before inference. Its total cap calculation is deliberately conservative: `max(reconciled baseline, observed account usage) + all recorded charges or reservations + new reservation <= $200`. It may double-count already reconciled costs. This can stop a run early, but cannot silently discard pending spend when account usage is stale.

Ledger format 2 rejects earlier format 1 without migration or reset. Preserve old ledgers for reconciliation. Live launch permits require explicit task IDs; only mock permits allow empty slots that bind on their first validated request.

The ledger stores experiment transport labels, identities, digests, model, account usage observations, timestamps, token counts, reserved amounts, explicit provider costs, and outcomes. It stores no prompts, completions, keys, or headers. Unknown costs, cancellation, malformed replies, and interrupted inference retain an uncertain reservation and block more inference. Duplicate identities never repeat a provider request. Uncertainty requires a separately reviewed reconciliation; this helper has no refund, reset, or resume command.

The credential-attempt allowance is also durable. The first valid request consumes it before reading, including denied reads. Restarting the same experiment cannot attempt another Keychain read. A new experiment requires a new reconciled, explicitly approved launch permit. Account-level usage observations do not prove any individual request's cost.

## Live access boundary

No live access is part of the test command. Before the first `--live` launch, review the exact executable SHA-256 and signing metadata, reconcile all Vera testing against the shared cap, coordinate exclusive spend ownership, and obtain explicit approval for that build's one noninteractive access attempt to the selected saved OpenRouter profile. The saved profile must already select the fixed model and exact endpoint. Do not change installed settings to satisfy this prototype.

Selected-profile validation reads only the existing settings file and uses its active profile ID, endpoint and model. Its separate bounded reader accepts an owner-owned directory readable by others, but rejects group or world writes, symlinks and nonregular or multiply linked files. The settings file must remain owner-owned and private. Permit and ledger directory checks still require private directories. Validation does not change files or permissions, copy unrelated settings, or emit configuration data.

The dormant reader uses only `SecItemCopyMatching` for service `org.displacedforest.vera.native-chat` and the exact account, with `LAContext.interactionNotAllowed = true`. It never adds, updates, deletes, prompts, retries, or falls back to another credential source. If the existing item's access policy denies this executable, stop. Any new grant, ACL, signing identity, or installed-app broker change needs a separate decision.

The wired Pi mock host creates grants from durable runtime identities and keeps credentials inside this process. It drains replies, cancels individual requests, kills a broken helper within a bound, and waits for child exit. A canceled request proven not written does not cancel the other role. Missing responses retain uncertain state. Native Pi invocations use a 150-second deadline and the dispatcher uses 160 seconds, covering four 35-second host waits and cleanup; the helper itself retains its 30-second request deadline. Two foreground conversations queue before turn acceptance, while the worker remains independent. Host request grants are bounded to 12 and retained for audit. Cloud results would establish transport behavior only, not local MLX speed or quality.

The noninteractive query follows [Apple's authentication-context guidance](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail). Routing controls follow [OpenRouter provider selection](https://openrouter.ai/docs/guides/routing/provider-selection), and cost receipts follow [usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting).


The mock host mints only `transport:mock` permits and always invokes `--mock-pi-stdio`. These grants cannot activate live access. Its baseline and cost observations are synthetic. The bounded experiment deliberately expires and has only two foreground invocation slots and one worker slot; it does not silently rotate grants or reset a ledger when those limits or a recovery fence are reached. Missing grants over existing state and changed binaries refuse startup. Reopening a task under a different transport fails before any workspace operation. A fresh live experiment would need explicit reviewed host enablement and its own approved `transport:live` grant with reconciled real spend.
