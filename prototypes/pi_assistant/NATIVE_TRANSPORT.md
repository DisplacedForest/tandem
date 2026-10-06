# Proposed native test transport boundary

Status: a separate [native helper](../native-transport/README.md) now implements this boundary and has mock credential, fixture HTTP, and process interruption tests. It is not connected to the Pi adapter or approved for live access. No new Keychain query, grant, access-list change, signing change, app installation, or paid request has been performed. The existing installed binary has no general completion broker; it cannot expose this contract without a reviewed binary change. Its fixed smoke command and research relay are not reusable by silently widening their allowed input.

## Smallest permitted next step

Run `mise run pi-native-transport-test` to build and verify the separate helper with synthetic credentials and injected HTTP first. Its live credential reader would reuse `KeychainNativeCredentialStore(allowsInteraction:false)` in-process and query only the explicitly selected saved profile. A separate executable may not be trusted by the existing Keychain item's access control. An unavailable credential must return `credential_unavailable` immediately, with no prompt, alternate credential source, retry, shell invocation, or file export.

Only after mock review, the parent must approve one noninteractive access attempt by the exact reviewed helper binary identity for the selected profile. This is not approval to add a persistent grant. If existing access does not permit that identity, stop and report that a new credential access decision or a separately approved installed-app broker change would be required. Do not arrange either during the idle observation or travel preparation. Current authorization to spend on model testing does not itself change Keychain access.

## Request contract

The helper is launched by the host over private inherited pipes, with no listening TCP port and no environment credential. The host grants one random, nonsecret session identity, task identity, exact input digest, role and bounded request allowance. The helper validates each envelope before acquiring a credential. Stdin closure cancels in-flight URLSession tasks and exits. No request text or tool output is written to diagnostic logs.

The request contains a request UUID, session/task identities, model-context messages and a declared role. The native helper translates Pi's typed message representation to OpenAI messages itself. It accepts only the fixture tool names appropriate to that role: foreground `delegate`, worker `read_file`, `write_file`, `check_python`. Tool definitions are compiled into the helper rather than supplied as arbitrary JSON schemas. Tool results must match a preceding call ID. Reject unknown fields, malformed messages, image URLs, arbitrary providers, arbitrary URLs, unpaired tool results, excessive context and unsupported roles. The helper returns bounded typed text/tool calls and usage metadata, never headers or raw response bodies. Tool arguments are still untrusted; Python retains execution validation and approval.

## Provider and limits

Pin the only model to `qwen/qwen3.8-flash` and the only origin to `https://openrouter.ai`, default TLS validation, no redirects or alternate endpoints. Use `/api/v1/chat/completions` for inference and read-only `/api/v1/models` and `/api/v1/key` for capability/pricing and cumulative usage. Disable provider fallback and reasoning. Require the requested model and parameters; do not substitute a model after failure.

Before execution, verify current official model pricing and supported parameters. Fix a maximum of 256 output tokens and a conservatively bounded input (including schemas) per call, four turns/eight tools per agent invocation, at most two foreground invocations and one worker invocation per live experiment, and a $1 subbudget within the existing $200 total Vera testing ceiling. Concurrency is one foreground request plus one worker request, each with its own URLSession task and 30-second deadline. There are no transparent paid retries.

The helper is the single spend authority for these live runs. Use an exclusive lock and a FULL-synchronous durable ledger to reserve the conservative maximum charge before issuing each request, including simultaneous foreground and worker requests. Include existing cumulative usage and all pending reservations. If another test owner cannot be reconciled with the shared budget, refuse to begin. A crash or ambiguous provider result retains the reservation until reconciled, never refunds it automatically. A duplicate request ID with a different digest conflicts; a duplicate unresolved request blocks rather than issuing another paid request.

Record request IDs, model ID, nonsecret session/task identities, start/end outcome, token counts, explicit provider cost receipts when available, reserved amount and reconciled account usage. Do not store prompts, completions, credentials, headers or raw error bodies in the cost ledger. Usage deltas are account-level observations, not per-request cost receipts. Validate all prices and costs as finite nonnegative decimal values. Reject missing or unfamiliar billable pricing dimensions before execution. Unknown cost consumes its reservation and blocks further calls pending reconciliation.

## Review and test requirements

Use injected credential and URLSession transports to prove no credential access before validation; rejection of host/model changes, redirects, schema/context overflows and foreign session IDs; one charge reservation under concurrent duplicates; cumulative and per-run caps; uncertain-charge retention after kill; timeout and stdin-close cancellation; empty/malformed/provider-error response handling; response-size limits; missing Keychain access without UI; redacted error output; and no secret in child process arguments, environment, requests to the model, files or logs.

Then run a bounded live experiment only after the remaining native access boundary is explicitly resolved. Report acceptance, foreground reply and worker completion separately, retain the ledger, and label results as cloud transport evidence only.
