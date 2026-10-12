import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "apps/vera-mac/scripts/sign.py"
SPEC = importlib.util.spec_from_file_location("vera_sign", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Vera.app"
        self.app.mkdir()
        self.config = self.root / "vera/signing.json"
        self.config.parent.mkdir()
        self.environment = {"XDG_CONFIG_HOME": str(self.root)}
        self.identity = "a1" * 20

    def save(self, value):
        self.config.write_text(json.dumps(value))

    def test_default_remains_ad_hoc_and_verifies(self):
        with patch.object(signing.subprocess, "run") as run:
            signing.sign(self.app, self.environment)
        self.assertEqual(run.call_args_list[0].args[0][1:5], ["--force", "--deep", "--sign", "-"])
        self.assertIn("--strict", run.call_args_list[1].args[0])

    def test_persistent_fingerprint_and_keychain_are_passed_as_arguments(self):
        keychain = self.root / "login keychain-db"
        keychain.touch()
        self.save({"identity": self.identity, "keychain": str(keychain)})
        with patch.object(signing.subprocess, "run") as run:
            signing.sign(self.app, self.environment)
        command = run.call_args_list[0].args[0]
        self.assertIn(self.identity.upper(), command)
        self.assertEqual(command[command.index("--keychain") + 1], str(keychain))
        self.assertIn("--timestamp=none", command)

    def test_explicit_override_selects_ad_hoc(self):
        self.save({"identity": self.identity})
        environment = {**self.environment, "VERA_SIGNING_IDENTITY": "-"}
        self.assertEqual(signing.settings(environment), ("-", None))

    def test_invalid_configuration_never_signs(self):
        for value in ({}, {"identity": "friendly name"}, {"identity": ""}, {"identity": self.identity, "extra": True}, {"identity": self.identity, "keychain": 4}, {"identity": self.identity, "keychain": "relative"}, []):
            with self.subTest(value=value):
                self.save(value)
                with patch.object(signing.subprocess, "run") as run:
                    with self.assertRaises(ValueError):
                        signing.sign(self.app, self.environment)
                    run.assert_not_called()

    def test_configuration_is_never_executed(self):
        marker = self.root / "executed"
        self.config.write_text(f"$(touch {marker})")
        with self.assertRaises(ValueError):
            signing.settings(self.environment)
        self.assertFalse(marker.exists())

    def test_missing_explicit_configuration_fails(self):
        with self.assertRaises(ValueError):
            signing.settings({"VERA_SIGNING_CONFIG": str(self.root / "missing.json")})

    def test_failed_identity_does_not_fall_back_or_verify(self):
        self.save({"identity": self.identity})
        with patch.object(signing.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "codesign")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                signing.sign(self.app, self.environment)
        self.assertEqual(run.call_count, 1)

    def test_environment_can_override_exact_identity(self):
        self.save({"identity": self.identity})
        other = "b2" * 20
        self.assertEqual(signing.settings({**self.environment, "VERA_SIGNING_IDENTITY": other})[0], other.upper())


if __name__ == "__main__":
    unittest.main()
