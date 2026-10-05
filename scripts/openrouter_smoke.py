import argparse
import base64
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib
from decimal import Decimal, InvalidOperation
from typing import Any, Callable

API_ROOT = "https://openrouter.ai/api/v1"
MAX_REQUESTS = 3
MAX_OUTPUT_TOKENS = 256
INPUT_TOKEN_ALLOWANCE = 4096
MAX_RESPONSE_BYTES = 2_000_000
TOOL = {
    "type": "function",
    "function": {
        "name": "synthetic_add",
        "description": "Add the two supplied synthetic integers.",
        "parameters": {
            "type": "object",
            "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
            "required": ["a", "b"],
            "additionalProperties": False,
        },
    },
}


class SmokeError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str,
                         headers: Any, newurl: str) -> None:
        raise SmokeError("HTTP redirect refused")


def request_json(path: str, payload: dict[str, Any] | None = None,
                 key: str | None = None) -> dict[str, Any]:
    if path not in ("/models", "/chat/completions"):
        raise SmokeError("Unsupported API path")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(API_ROOT + path, data=data, headers=headers)
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise SmokeError("Response exceeded size limit")
        result = json.loads(raw)
        if not isinstance(result, dict):
            raise SmokeError("Response was not an object")
        return result
    except urllib.error.HTTPError as error:
        raise SmokeError(f"HTTP {error.code}; response body withheld") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        raise SmokeError("Network or JSON response failure; details withheld") from None


def catalog_model(catalog: dict[str, Any], model_id: str) -> dict[str, Any]:
    entries = catalog.get("data")
    if not isinstance(entries, list) or any(not isinstance(m, dict) for m in entries):
        raise SmokeError("Malformed model catalog")
    matches = [m for m in entries if m.get("id") == model_id]
    if len(matches) != 1:
        raise SmokeError("Exact model ID unavailable; no substitute selected")
    model = matches[0]
    if model.get("alias_target"):
        raise SmokeError("Moving model aliases are not accepted")
    return model


def price(value: Any) -> Decimal:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise SmokeError("Missing or invalid pricing") from None
    if not result.is_finite() or result < 0:
        raise SmokeError("Missing or invalid pricing")
    return result


def forecast(model: dict[str, Any]) -> Decimal:
    pricing = model.get("pricing", {})
    if not isinstance(pricing, dict):
        raise SmokeError("Malformed model pricing")
    return MAX_REQUESTS * (
        INPUT_TOKEN_ALLOWANCE * price(pricing.get("prompt"))
        + MAX_OUTPUT_TOKENS * price(pricing.get("completion")))


def validate_model(model: dict[str, Any]) -> None:
    if (not isinstance(model.get("id"), str)
            or not isinstance(model.get("supported_parameters"), list)
            or any(not isinstance(p, str) for p in model["supported_parameters"])
            or not isinstance(model.get("architecture"), dict)
            or not isinstance(model["architecture"].get("input_modalities"), list)
            or not isinstance(model.get("reasoning"), dict)
            or not isinstance(model.get("pricing"), dict)):
        raise SmokeError("Malformed model metadata")
    required = {"tools", "tool_choice", "max_tokens", "reasoning"}
    if not required <= set(model.get("supported_parameters", [])):
        raise SmokeError("Model does not advertise all required smoke parameters")
    if "image" not in model.get("architecture", {}).get("input_modalities", []):
        raise SmokeError("Model does not advertise image input")
    if model.get("reasoning", {}).get("mandatory") is not False:
        raise SmokeError("Smoke requires explicitly optional reasoning")
    pricing = model.get("pricing", {})
    if pricing.get("overrides"):
        raise SmokeError("Tiered pricing needs a separate forecast")
    for name, value in pricing.items():
        if name not in ("prompt", "completion", "input_cache_read", "input_cache_write"):
            if price(value) != 0:
                raise SmokeError("Additional pricing needs a separate forecast")
    forecast(model)


def red_image() -> str:
    def chunk(kind: bytes, content: bytes) -> bytes:
        return (struct.pack("!I", len(content)) + kind + content
                + struct.pack("!I", zlib.crc32(kind + content)))
    pixels = (b"\x00" + b"\xff\x00\x00" * 32) * 32
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 32, 32, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    return "data:image/png;base64," + base64.b64encode(png).decode()


def synthetic_tool(message: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    calls = message.get("tool_calls", [])
    if not isinstance(calls, list) or len(calls) != 1:
        raise SmokeError("Expected exactly one synthetic tool call")
    call = calls[0]
    if not isinstance(call, dict):
        raise SmokeError("Malformed tool call")
    function = call.get("function", {})
    if not isinstance(function, dict) or call.get("type") != "function":
        raise SmokeError("Malformed tool function")
    if function.get("name") != "synthetic_add":
        raise SmokeError("Unknown tool refused")
    call_id = call.get("id")
    if not isinstance(call_id, str) or not call_id or len(call_id) > 128:
        raise SmokeError("Invalid tool call ID")
    try:
        arguments = json.loads(function["arguments"])
    except (KeyError, TypeError, ValueError):
        raise SmokeError("Malformed tool arguments") from None
    if (not isinstance(arguments, dict) or set(arguments) != {"a", "b"}
            or any(type(v) is not int for v in arguments.values())
            or arguments != {"a": 19, "b": 23}):
        raise SmokeError("Tool arguments did not match the synthetic fixture")
    assistant = {"role": "assistant", "content": None, "tool_calls": [{
        "id": call_id, "type": "function",
        "function": {"name": "synthetic_add", "arguments": json.dumps(arguments)},
    }]}
    result = {"role": "tool", "tool_call_id": call_id,
              "content": json.dumps({"result": arguments["a"] + arguments["b"]})}
    return assistant, result


def run_smoke(model: dict[str, Any], budget: Decimal,
              post: Callable[[dict[str, Any]], dict[str, Any]]) -> dict[str, Any]:
    validate_model(model)
    estimate = forecast(model)
    if not budget.is_finite() or budget <= 0 or estimate > budget:
        raise SmokeError("Forecast exceeds approved budget or budget is invalid")
    pricing = model["pricing"]
    spent = Decimal(0)
    requests = 0
    measurements: list[dict[str, Any]] = []

    def complete(messages: list[dict[str, Any]], use_tool: bool = False) -> dict[str, Any]:
        nonlocal requests, spent
        if requests >= MAX_REQUESTS or spent + estimate / MAX_REQUESTS > budget:
            raise SmokeError("Request or remaining budget limit reached")
        body: dict[str, Any] = {
            "model": model["id"], "messages": messages, "stream": False,
            "max_tokens": MAX_OUTPUT_TOKENS, "reasoning": {"enabled": False},
            "provider": {"allow_fallbacks": False, "require_parameters": True,
                         "max_price": {"prompt": float(price(pricing["prompt"]) * 1_000_000),
                                       "completion": float(price(pricing["completion"]) * 1_000_000)}},
        }
        if use_tool:
            body.update(tools=[TOOL], tool_choice={"type": "function",
                        "function": {"name": "synthetic_add"}})
        started = time.monotonic()
        requests += 1
        response = post(body)
        elapsed = time.monotonic() - started
        if response.get("error") or response.get("model") != model["id"]:
            raise SmokeError("Provider error or response model mismatch")
        usage = response.get("usage")
        if not isinstance(usage, dict) or usage.get("cost") is None:
            raise SmokeError("Missing usage cost; stopping before another request")
        cost = price(usage["cost"])
        spent += cost
        measurements.append({"request": requests, "seconds": round(elapsed, 3), "cost_usd": str(cost)})
        if spent > budget:
            raise SmokeError("Reported cost exceeded approved budget; stopped")
        choices = response.get("choices")
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            raise SmokeError("Missing or malformed completion")
        choice = choices[0]
        expected_finish = "tool_calls" if use_tool else "stop"
        if choice.get("finish_reason") != expected_finish or not isinstance(choice.get("message"), dict):
            raise SmokeError("Unexpected completion termination")
        return choice["message"]

    messages: list[dict[str, Any]] = [{"role": "user", "content":
        "Call synthetic_add with a=19 and b=23. After the tool result, reply with only the result integer."}]
    assistant, result = synthetic_tool(complete(messages, use_tool=True))
    messages += [assistant, result]
    final = complete(messages)
    if final.get("tool_calls") or str(final.get("content", "")).strip() != "42":
        raise SmokeError("Tool continuation did not return 42")
    image_result = complete([{"role": "user", "content": [
        {"type": "text", "text": "What is the solid color of this image? Reply with one lowercase color word."},
        {"type": "image_url", "image_url": {"url": red_image()}},
    ]}])
    if image_result.get("tool_calls") or str(image_result.get("content", "")).strip().lower() != "red":
        raise SmokeError("Image recognition did not return red")
    return {"mode": "live", "model": model["id"], "requests": requests,
            "tool_call": "passed", "tool_continuation": "passed", "image_input": "passed",
            "cost_usd": str(spent), "measurements": measurements}


def budget_argument(value: str) -> Decimal:
    try:
        budget = price(value)
    except SmokeError:
        raise argparse.ArgumentTypeError("Budget must be a finite positive USD amount") from None
    if budget <= 0:
        raise argparse.ArgumentTypeError("Budget must be a finite positive USD amount")
    return budget


def main() -> int:
    parser = argparse.ArgumentParser(description="Synthetic-only OpenRouter catalog preflight and smoke test")
    parser.add_argument("--model", required=True, help="Exact catalog ID; no automatic substitution")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--approved-budget-usd", type=budget_argument)
    args = parser.parse_args()
    try:
        model = catalog_model(request_json("/models"), args.model)
        validate_model(model)
        print(json.dumps({"mode": "preflight", "model": model["id"],
                          "hugging_face_id": model.get("hugging_face_id"),
                          "context_length": model.get("context_length"),
                          "pricing": model.get("pricing"),
                          "input_modalities": model.get("architecture", {}).get("input_modalities"),
                          "forecast_usd": str(forecast(model)), "max_requests": MAX_REQUESTS,
                          "max_output_tokens_per_request": MAX_OUTPUT_TOKENS}), flush=True)
        if not args.live:
            return 0
        if args.approved_budget_usd is None:
            raise SmokeError("Live calls require an explicitly approved budget")
        key = os.environ.get("OPENROUTER_API_KEY", "").strip()
        if not key:
            raise SmokeError("OPENROUTER_API_KEY is not configured; do not paste a key into chat")
        result = run_smoke(model, args.approved_budget_usd,
                           lambda body: request_json("/chat/completions", body, key))
        print(json.dumps(result))
        return 0
    except SmokeError as error:
        print(json.dumps({"status": "blocked_or_failed", "reason": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
