import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "name-ratchet.py")
SOURCES = os.path.join("apps", "vera-mac", "Sources", "Vera")


class NameRatchetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name
        os.makedirs(os.path.join(self.root, SOURCES))
        os.makedirs(os.path.join(self.root, "scripts"))
        self.baseline = os.path.join(self.root, "scripts", "baseline.txt")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, lines):
        with open(os.path.join(self.root, SOURCES, name), "w") as handle:
            handle.write("\n".join(lines) + "\n")

    def run_script(self, *extra):
        return subprocess.run(
            [sys.executable, SCRIPT, "--root", self.root, "--baseline", self.baseline, *extra],
            capture_output=True,
            text=True,
        )

    def test_added_literal_fails_with_file_and_line(self):
        self.write("A.swift", ['let a = "Vera one"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.run_script().returncode, 0)
        self.write("A.swift", ['let a = "Vera one"', "let b = 1", 'let c = "Vera two"'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A.swift:3", result.stdout)

    def test_new_file_with_a_literal_fails(self):
        self.write("A.swift", ["let a = 1"])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("B.swift", ['let b = "Ask Vera"'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("B.swift:1", result.stdout)

    def test_removed_literal_asks_for_update_then_passes(self):
        self.write("A.swift", ['let a = "Vera one"', 'let c = "Vera two"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("A.swift", ['let a = "Vera one"'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--update", result.stdout)
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.run_script().returncode, 0)

    def test_update_refuses_an_increase(self):
        self.write("A.swift", ['let a = "Vera one"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("A.swift", ['let a = "Vera one"', 'let c = "Vera two"'])
        before = open(self.baseline).read()
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(open(self.baseline).read(), before)

    def test_other_words_do_not_count(self):
        self.write("A.swift", ['let a = "Veranda"', 'let b = Vera', 'let c = "vera"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(open(self.baseline).read(), "")


if __name__ == "__main__":
    unittest.main()
