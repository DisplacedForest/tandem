import copy
import importlib.util
import io
import urllib.error
import json
import pathlib
import unittest
from decimal import Decimal
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "openrouter_smoke", pathlib.Path(__file__).parents[1] / "openrouter_smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def model():
    return {"id": "test/synthetic", "architecture": {"input_modalities": ["text", "image"]},
            "supported_parameters": ["tools", "tool_choice", "max_tokens", "reasoning"],
            "reasoning": {"mandatory": False},
            "pricing": {"prompt": "0.00000015", "completion": "0.00000047"}}


def tool_message():
    return {"role": "assistant", "tool_calls": [{"id": "synthetic-call", "type": "function",
            "function": {"name": "synthetic_add", "arguments": '{"a":19,"b":23}'}}]}


def completion(message, finish="stop", cost="0.0001"):
    return {"model": "test/synthetic", "choices": [{"message": message, "finish_reason": finish}],
            "usage": {"cost": cost}}


class SmokeTests(unittest.TestCase):
    def test_synthetic_round_trip_and_request_boundaries(self):
        replies = [completion(tool_message(), "tool_calls"),
                   completion({"content": "42"}), completion({"content": "red"})]
        bodies = []

        def post(body):
            bodies.append(copy.deepcopy(body))
            return replies.pop(0)

        report = smoke.run_smoke(model(), Decimal("0.01"), post)
        self.assertEqual(report["requests"], 3)
        self.assertEqual(report["cost_usd"], "0.0003")
        for body in bodies:
            self.assertEqual(body["model"], "test/synthetic")
            self.assertEqual(body["max_tokens"], 256)
            self.assertEqual(body["reasoning"], {"enabled": False})
            self.assertEqual(body["provider"], {"allow_fallbacks": False, "require_parameters": True,
                                               "max_price": {"prompt": 0.15, "completion": 0.47}})
        self.assertEqual(bodies[0]["tools"], [smoke.TOOL])
        self.assertNotIn("tools", bodies[1])
        self.assertEqual(json.loads(bodies[1]["messages"][-1]["content"]), {"result": 42})
        self.assertEqual(bodies[2]["messages"][0]["content"][1]["image_url"]["url"], smoke.red_image())

    def test_exact_model_only(self):
        with self.assertRaisesRegex(smoke.SmokeError, "no substitute"):
            smoke.catalog_model({"data": [model()]}, "test/unavailable")
        alias = model() | {"alias_target": {"slug": "other/model"}}
        with self.assertRaises(smoke.SmokeError):
            smoke.catalog_model({"data": [alias]}, alias["id"])

    def test_malformed_catalog_and_metadata_fail_cleanly(self):
        for catalog in ({"data": None}, {"data": ["bad"]}, {}):
            with self.assertRaises(smoke.SmokeError):
                smoke.catalog_model(catalog, "test/synthetic")
        for field in ("architecture", "reasoning", "pricing", "supported_parameters"):
            with self.assertRaises(smoke.SmokeError):
                smoke.validate_model(model() | {field: None})
        for value in ("bad", "NaN", "Infinity", "0", "-1"):
            with self.assertRaises(smoke.argparse.ArgumentTypeError):
                smoke.budget_argument(value)

    def test_budget_gate_precedes_post(self):
        for budget in ("0", "0.0001", "NaN", "Infinity", "-1"):
            with self.subTest(budget=budget), patch.object(smoke, "request_json") as post:
                with self.assertRaises(smoke.SmokeError):
                    smoke.run_smoke(model(), Decimal(budget), post)
                post.assert_not_called()
        self.assertEqual(smoke.forecast(model()), Decimal("0.00220416"))

    def test_unadvertised_capabilities_and_unforecast_prices_block(self):
        changed = [model() | {"supported_parameters": []},
                   model() | {"architecture": {"input_modalities": ["text"]}},
                   model() | {"reasoning": {"mandatory": True}},
                   model() | {"pricing": {"prompt": "NaN", "completion": "0"}},
                   model() | {"pricing": model()["pricing"] | {"image": "0.01"}},
                   model() | {"pricing": model()["pricing"] | {"overrides": [{}]}}]
        for entry in changed:
            with self.subTest(entry=entry), self.assertRaises(smoke.SmokeError):
                smoke.validate_model(entry)

    def test_invalid_tool_calls_never_execute(self):
        for arguments in ('bad-json', '{"a":true,"b":23}', '{"a":20,"b":23}',
                          '{"a":19,"b":23,"command":"anything"}', 'null'):
            message = tool_message()
            message["tool_calls"][0]["function"]["arguments"] = arguments
            with self.subTest(arguments=arguments), self.assertRaises(smoke.SmokeError):
                smoke.synthetic_tool(message)
        for calls in ([], [None], [tool_message()["tool_calls"][0]] * 2):
            with self.assertRaises(smoke.SmokeError):
                smoke.synthetic_tool({"tool_calls": calls})
        message = tool_message()
        message["tool_calls"][0]["function"]["name"] = "read_private_file"
        with self.assertRaisesRegex(smoke.SmokeError, "Unknown tool"):
            smoke.synthetic_tool(message)

    def test_errors_stop_without_retry(self):
        cases = [completion(tool_message(), "tool_calls") | {"model": "test/other"},
                 completion(tool_message(), "length"),
                 completion(tool_message(), "tool_calls") | {"usage": {}},
                 completion(tool_message(), "tool_calls", "1"), {"error": {"message": "sensitive"}}]
        for response in cases:
            with self.subTest(response=response), patch.object(smoke, "request_json", return_value=response) as post:
                with self.assertRaises(smoke.SmokeError) as error:
                    smoke.run_smoke(model(), Decimal("0.01"), post)
                self.assertNotIn("sensitive", str(error.exception))
                self.assertEqual(post.call_count, 1)

    def test_bad_tool_followup_stops_before_image(self):
        replies = [completion(tool_message(), "tool_calls"), completion({"content": "not 42"})]
        with patch.object(smoke, "request_json", side_effect=replies) as post:
            with self.assertRaises(smoke.SmokeError):
                smoke.run_smoke(model(), Decimal("0.01"), post)
            self.assertEqual(post.call_count, 2)

    def test_network_path_allowlist_and_redirect_refusal(self):
        with self.assertRaises(smoke.SmokeError):
            smoke.request_json("https://other.example")
        with self.assertRaises(smoke.SmokeError):
            smoke.NoRedirect().redirect_request(None, None, 302, "", None, "https://other.example")

    def test_http_errors_do_not_expose_response_or_key(self):
        sentinel = "synthetic-sensitive-sentinel"
        error = urllib.error.HTTPError("https://openrouter.ai/" + sentinel, 401, sentinel,
                                       {"Authorization": sentinel}, io.BytesIO(sentinel.encode()))
        with patch.object(smoke.urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = error
            with self.assertRaises(smoke.SmokeError) as failure:
                smoke.request_json("/chat/completions", {}, sentinel)
            self.assertNotIn(sentinel, str(failure.exception))
            self.assertIn("401", str(failure.exception))

    def test_live_cli_missing_key_stops_before_post(self):
        with patch("sys.argv", ["smoke", "--model", "test/synthetic", "--live",
                                "--approved-budget-usd", "0.01"]), \
             patch.dict(smoke.os.environ, {}, clear=True), \
             patch.object(smoke, "request_json", return_value={"data": [model()]}) as request, \
             patch("builtins.print"):
            self.assertEqual(smoke.main(), 1)
            request.assert_called_once_with("/models")

    def test_default_cli_is_catalog_only(self):
        with patch("sys.argv", ["smoke", "--model", "test/synthetic"]), \
             patch.object(smoke, "request_json", return_value={"data": [model()]}) as request, \
             patch("builtins.print"):
            self.assertEqual(smoke.main(), 0)
            request.assert_called_once_with("/models")

    def test_live_cli_requires_budget(self):
        with patch("sys.argv", ["smoke", "--model", "test/synthetic", "--live"]), \
             patch.object(smoke, "request_json", return_value={"data": [model()]}) as request, \
             patch("builtins.print"):
            self.assertEqual(smoke.main(), 1)
            request.assert_called_once_with("/models")


if __name__ == "__main__":
    unittest.main()
