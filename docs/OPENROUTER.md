# OpenRouter evaluation

Vera's native client supports OpenRouter through its existing OpenAI-compatible endpoint configuration. This guide prepares an optional cloud evaluation. Normal conversations can contain persona, memory, knowledge, attachments, and tool results. Use the isolated synthetic harness below to evaluate a provider before connecting normal chat.

## Model identity

Checked against the [OpenRouter catalog](https://openrouter.ai/api/v1/models) on October 5, 2026:

| Field | Catalog value |
| --- | --- |
| API model ID | `qwen/qwen3.8-flash` |
| Display name | Qwen: Qwen3.8 Flash |
| Linked weights | `Qwen/Qwen3.8-Flash-Next` |
| Inputs / output | Text, images, video / text |
| Context / maximum completion | 1,000,000 / 131,072 tokens |
| Tool parameters | `tools`, `tool_choice` |
| Reasoning | Optional, enabled by default |
| Input / output price | $0.15 / $0.47 per million tokens |
| Cache read / write price | $0.016 / $0.20 per million tokens |

There is no separate `qwen/qwen3.8-flash-next` entry in that catalog snapshot. [Qwen describes](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) the hosted Qwen3.8 Flash as the official version based on Flash Next with additional production features. The catalog link establishes that relationship; it does not establish identical inference behavior to the open checkpoint. Choose the hosted ID explicitly before testing it. No harness default substitutes a different model.

[OpenRouter's model page](https://openrouter.ai/qwen/qwen3.8-flash) lists Alibaba Cloud Int. as a provider. Public listing does not prove account access or successful inference. Refresh the catalog and prices before each live run. Streaming and native app compatibility require separate validation. The harness covers non-streamed tool calling, a tool-result continuation, and one image input. It does not test video, audio, durable tasks, or native chat lifecycle behavior.

## Existing secure setup

In Vera, open **Settings > Endpoints > Saved endpoints > Add**. Set the saved name to OpenRouter and Base URL to `https://openrouter.ai/api/v1`. Enter the key in the existing **API key** secure field and use **Save**. Vera stores endpoint credentials in the Mac keychain, outside its JSON configuration and conversation records. Adding and saving an endpoint is a deliberate user setup action. It can change the active endpoint.

Then open **Settings > Model**, refresh discovery, and explicitly choose the approved exact model ID. For `qwen/qwen3.8-flash`, the current bundled name rules fall back to text-only. Under **Capabilities**, enable image input and tool calling, and set images per request to one for this evaluation. Do not configure a vision bridge for the direct-image smoke test. This guide does not modify saved endpoints, capabilities, credentials, or the active model.

The standalone harness reads an already configured `OPENROUTER_API_KEY` only for an authorized live run. It neither opens Keychain nor reads Vera's settings, conversations, memory, home files, or project files. Do not put a key in this repository, a command argument, a report, or chat. The app's keychain credential and the harness environment credential are separate supported paths; the harness does not extract the app's key.

## Synthetic smoke test

From the repository root, the free preflight fetches the public catalog without authorization headers:

```sh
python3 scripts/openrouter_smoke.py --model qwen/qwen3.8-flash
```

Offline tests use only mocked model responses and make no network calls:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_openrouter_smoke.py' -v
```

A live run requires both an exact model choice and explicit budget approval. After the person paying approves that model and a $0.01 test budget, with the credential already securely supplied to the process:

```sh
python3 scripts/openrouter_smoke.py --model qwen/qwen3.8-flash --live --approved-budget-usd 0.01
```

The budget flag records approval; its presence is not a substitute for obtaining approval. At the catalog prices above, three requests with 4,096 input tokens allowed for each and at most 256 output tokens each forecast **$0.00220416**. Input tokens are an estimate, including image tokenization, not a provider-enforced token ceiling. The budget is a preflight and between-request stop condition, not an account spending limit or a guarantee against overbilling. Provider price ceilings reject routes above the catalog token rates. Reported usage cost is required before the next request. No purchases or automatic retries occur.

The first request forces a single `synthetic_add(19, 23)` call. The harness validates the exact name and arguments, calculates 42 locally, and sends a sanitized assistant/tool exchange for the second request. The third request contains a programmatically generated 32 by 32 red PNG and asks for its color. No arbitrary returned tool executes. Calls, outputs, response size, and individual HTTP operations are bounded. HTTP redirects are refused. Unknown models, moving aliases, unsupported capabilities, tiered or additional pricing, invalid tool arguments, response-model mismatches, missing usage, and incomplete completions stop the run.

Reports contain the exact model, pass/fail checks, durations, and reported costs. Response bodies, authorization headers, and keys are withheld on errors. A failed request can still incur cost; consult the provider's usage page if a failure prevents a usage receipt. A mocked pass establishes harness behavior only. Only a successful authorized live run establishes provider behavior.


## Test with the saved Vera credential

If the OpenRouter key is already saved in Vera, use the native test entry point so the key never needs to be entered again or exported to another process. Build the app, then run from `apps/vera-mac`:

```sh
.build/debug/Vera --openrouter-smoke --credential-status
.build/debug/Vera --openrouter-smoke --access-status
.build/debug/Vera --openrouter-smoke --model qwen/qwen3.8-flash
```

The first command reads only the active saved endpoint and checks the existing Keychain store with interaction disabled. It prints a boolean, never the key. The access-status command validates that credential using the free key-status endpoint and prints only whether authentication succeeded. The model preflight refreshes the public catalog and forecast without reading the key. None of these commands writes configuration or credentials. A missing model selection in the app is acceptable because the test requires its own explicit model ID.

With the model and credit usage authorized, run:

```sh
.build/debug/Vera --openrouter-smoke --model qwen/qwen3.8-flash --live --approved-budget-usd 0.01
```

This uses the native request builder and response parser with fresh synthetic messages. It does not initialize the app's configuration store, import a persona, load conversations, enable tools, or access project/Home data. The only callable test tool adds the fixed integers. The saved key stays in the native process and is sent only as authentication to the saved, validated OpenRouter HTTPS API root. No environment key fallback or second credential lookup is attempted. Redirects, persistent URL caches, and cookie storage are disabled. Each request has a 45-second resource deadline and a two-megabyte response limit.

If the saved credential cannot be read without user interaction, the command stops without opening a Keychain prompt. A successful credential-availability check is not authentication validation. An HTTP authentication, account-limit, or provider error stops the test without retries or alternate keys. Both harnesses use the same three-request plan and forecast, and both stop between requests when reported cost leaves insufficient budget. The native command reports each usage receipt before checking the final result.

`mise run check` includes the offline native provider self-test. Run it separately with `.build/debug/Vera --provider-smoke-selftest`. Native provider smoke results do not establish API worker integration: the server's `model_client` authentication path is separate.
