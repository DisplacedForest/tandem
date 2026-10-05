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
