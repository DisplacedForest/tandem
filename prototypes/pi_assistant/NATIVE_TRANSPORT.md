# Proposed native test transport boundary

Status: the separate [native helper](../native-transport/README.md) has mock credential, fixture HTTP and process interruption tests. The integrated app candidate in README.md owns its UI, runtime, selected-profile operation, admission and accounting, using explicit fixture credentials and provider responses. Its public launch command is mock-only. The installed app has no general Pi completion broker, so its fixed smoke command and research relay cannot expose this contract without a code change.

## Live activation boundary

The candidate factory constructs `PiCandidateCredentials`, `PiCandidateProviderFixture` and `PiAdmissionFixtureProtocol`. Unknown live candidate flags are rejected. Activation requires an app-owned factory using the existing committed selected-profile operation, a bounded redirect-refusing HTTP transport, configured admission, reconciled cumulative test accounting, and accurate live transport labels throughout the bridge and UI. Pricing and model compatibility must be checked before bounded inference.

A normal upgrade signed with the same existing app identity may retain that app's current credential access. It does not inherently require a new credential grant or approval for each build. A separate helper's refusal does not prove that the authorized app also lacks access. Signature metadata alone cannot prove successful Keychain access, either. Verify through the ordinary app-owned noninteractive selected-profile boundary, keeping the key in the app and respecting the existing model-testing authorization and budget.

If that existing boundary refuses access, stop that access attempt. Do not retry through a different identity, change an access list, trust or signing setting, export the key, or create a persistent grant as a workaround. Such a change is distinct from an ordinary same-identity rebuild or authorized model test and needs its own explicit scope. Installation remains separate from this isolated prototype's launch command.

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
