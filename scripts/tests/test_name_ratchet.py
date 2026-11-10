import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "name-ratchet.py")
SOURCES = os.path.join("apps", "vera-mac", "Sources", "Vera")
SECOND = os.path.join("prototypes", "assistant-ui", "Sources", "VeraAssistantUI")


class NameRatchetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name
        os.makedirs(os.path.join(self.root, SOURCES))
        os.makedirs(os.path.join(self.root, SECOND))
        os.makedirs(os.path.join(self.root, "scripts"))
        self.baseline = os.path.join(self.root, "scripts", "baseline.txt")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, lines, folder=SOURCES):
        with open(os.path.join(self.root, folder, name), "w") as handle:
            handle.write("\n".join(lines) + "\n")

    def baseline_text(self):
        with open(self.baseline) as handle:
            return handle.read()

    def counts(self, lines):
        self.write("T.swift", lines)
        self.run_script("--update")
        text = self.baseline_text().strip()
        return int(text.split()[0]) if text else 0

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
        before = self.baseline_text()
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.baseline_text(), before)

    def test_multiline_string_counts_once_at_its_first_line(self):
        self.write("A.swift", ["let a = 1", 'let b = """', "  hello", "  Vera is here", '  """'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.baseline_text().split()[0], "1")
        self.write("A.swift", ["let a = 1", 'let b = """', "  hello", "  Vera is here", '  """', 'let c = """', "  Vera", '  """'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A.swift:6", result.stdout)

    def test_multiline_string_with_a_continuation(self):
        self.assertEqual(self.counts(['let b = """', "  Ask \\", "  Vera now", '  """']), 1)

    def test_raw_strings(self):
        self.assertEqual(self.counts(['let a = #"Ask "Vera" now"#', 'let b = ##"x "# Vera"##']), 2)

    def test_raw_multiline_string(self):
        self.assertEqual(self.counts(['let a = #"""', '  say "Vera" """ again', '  """#']), 1)

    def test_literal_nested_in_an_interpolation(self):
        self.assertEqual(self.counts(['let a = "Hello \\(name ?? "Vera")"']), 1)

    def test_nested_interpolation_in_a_raw_string(self):
        self.assertEqual(self.counts(['let a = #"Hi \\#(who ?? "Vera") there"#']), 1)

    def test_outer_literal_without_the_word_is_not_counted_for_interpolated_code(self):
        self.assertEqual(self.counts(['let a = "Hello \\(Vera.name)"']), 0)

    def test_comments_are_skipped_including_nested_blocks(self):
        lines = ["/* outer /* inner \"Vera\" */ still \"Vera\" comment */", 'let a = "fine"', '// "Vera" in a line comment']
        self.assertEqual(self.counts(lines), 0)

    def test_escaped_quote_before_the_word(self):
        self.assertEqual(self.counts(['let a = "say \\"Vera\\" now"']), 1)

    def test_comment_markers_inside_strings_are_not_comments(self):
        self.assertEqual(self.counts(['let a = "http://x /* Vera */"']), 1)

    def test_literal_added_in_a_second_root_fails(self):
        self.write("A.swift", ["let a = 1"])
        self.write("B.swift", ["let b = 1"], SECOND)
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("B.swift", ['let b = "Vera"'], SECOND)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VeraAssistantUI/B.swift:1", result.stdout)

    def test_unscanned_local_package_fails(self):
        manifest = os.path.join(self.root, "apps", "vera-mac", "Package.swift")
        with open(manifest, "w") as handle:
            handle.write('dependencies: [.package(path: "../../prototypes/assistant-ui"), .package(path: "../../prototypes/other")]\n')
        self.write("A.swift", ["let a = 1"])
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("prototypes/other", result.stdout)

    def test_covered_local_package_passes(self):
        manifest = os.path.join(self.root, "apps", "vera-mac", "Package.swift")
        with open(manifest, "w") as handle:
            handle.write('dependencies: [.package(path: "../../prototypes/assistant-ui")]\n')
        self.write("A.swift", ["let a = 1"])
        self.assertEqual(self.run_script("--update").returncode, 0)

    def test_extended_regex_literal_hides_a_quote(self):
        self.assertEqual(self.counts(['let regex = #/"/#; let label = "Vera"']), 1)

    def test_extended_regex_literal_body_is_not_a_string(self):
        self.assertEqual(self.counts(['let regex = #/"Vera"/#']), 0)

    def test_multiline_extended_regex_literal(self):
        self.assertEqual(self.counts(["let regex = ##/", '  "Vera" /# still', "/##", 'let label = "Vera"']), 1)

    def manifest(self, line):
        path = os.path.join(self.root, "apps", "vera-mac", "Package.swift")
        with open(path, "w") as handle:
            handle.write("dependencies: [\n" + line + "\n]\n")
        self.write("A.swift", ["let a = 1"])

    def test_raw_string_package_path_is_checked(self):
        self.manifest('.package(path: #"../../prototypes/other"#),')
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("prototypes/other", result.stdout)

    def test_package_path_after_another_argument_is_checked(self):
        self.manifest('.package(name: "Other", path: "../../prototypes/other"),')
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("prototypes/other", result.stdout)

    def test_unreadable_package_path_fails_with_its_line(self):
        self.manifest(".package(path: otherPath),")
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Package.swift:2", result.stdout)

    def test_covered_package_and_remote_package_pass(self):
        self.manifest('.package(url: "https://example.com/path: x.git", from: "1.0.0"),\n.package(name: "UI", path: "../../prototypes/assistant-ui"),')
        self.assertEqual(self.run_script("--update").returncode, 0)

    def test_other_words_do_not_count(self):
        self.write("A.swift", ['let a = "Veranda"', 'let b = Vera', 'let c = "vera"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.baseline_text(), "")


if __name__ == "__main__":
    unittest.main()
