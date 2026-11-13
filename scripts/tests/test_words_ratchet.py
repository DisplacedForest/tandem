import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "words-ratchet.py")
SOURCES = os.path.join("apps", "vera-mac", "Sources", "Vera")
SECOND = os.path.join("prototypes", "assistant-ui", "Sources", "VeraAssistantUI")


class WordsRatchetTests(unittest.TestCase):
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

    def run_script(self, *extra):
        return subprocess.run(
            [sys.executable, SCRIPT, "--root", self.root, "--baseline", self.baseline, *extra],
            capture_output=True,
            text=True,
        )

    def counts(self, lines):
        self.write("T.swift", lines)
        self.assertEqual(self.run_script("--update").returncode, 0)
        text = self.baseline_text().strip()
        return int(text.split()[0]) if text else 0

    def test_added_prose_literal_fails_with_file_and_line(self):
        self.write("A.swift", ['let a = "Stop this task"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.run_script().returncode, 0)
        self.write("A.swift", ['let a = "Stop this task"', "let b = 1", 'let c = "The engine is busy."'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A.swift:3", result.stdout)
        self.assertIn("The engine is busy.", result.stdout)

    def test_each_word_and_plural_counts_in_any_case(self):
        lines = ['let a%d = "%s"' % (i, word) for i, word in enumerate(
            ["A task", "Tasks", "BACKGROUND", "a worker", "Workers", "Agent", "agents", "engine", "Engines"])]
        self.assertEqual(self.counts(lines), 9)

    def test_identifiers_and_wire_values_do_not_count(self):
        lines = [
            'let a = "create_background_task"',
            'let b = "worker_type"',
            'let c = "taskID"',
            'let d = "backgroundTask"',
            'let e = "pi_worker"',
            'let f = "multitasking"',
            'let g = "agentic"',
            'let h = "engineRoot"',
            'let i = "task2"',
        ]
        self.assertEqual(self.counts(lines), 0)

    def test_separators_other_than_underscore_split_words(self):
        lines = ['let a = "User-Agent"', 'let b = "tasks/events"', 'let c = "task:"', 'let d = "com.vera.engine"']
        self.assertEqual(self.counts(lines), 4)

    def test_a_literal_counts_once_however_many_words_it_has(self):
        self.assertEqual(self.counts(['let a = "The task engine found a task"']), 1)

    def test_comments_are_skipped_including_nested_blocks(self):
        lines = ['/* outer /* inner "task" */ still "engine" comment */', 'let a = "fine"', '// "Background work" in a line comment']
        self.assertEqual(self.counts(lines), 0)

    def test_interpolated_literal_counts_on_its_own_words(self):
        self.assertEqual(self.counts(['let a = "This \\(kind) task stopped"']), 1)

    def test_word_only_in_interpolated_code_does_not_count(self):
        self.assertEqual(self.counts(['let a = "Hello \\(task.title)"']), 0)

    def test_interpolation_boundary_separates_words(self):
        self.assertEqual(self.counts(['let a = "\\(name)task"', 'let b = "task\\(name)"']), 2)

    def test_literal_nested_in_an_interpolation(self):
        self.assertEqual(self.counts(['let a = "Hello \\(name ?? "worker")"']), 1)

    def test_multiline_literal_counts_once_at_its_first_line(self):
        self.write("A.swift", ["let a = 1", 'let b = """', "  hello", "  the engine is here", '  """'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.baseline_text().split()[0], "1")
        self.write("A.swift", ["let a = 1", 'let b = """', "  hello", "  the engine is here", '  """', 'let c = """', "  Background", '  """'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A.swift:6", result.stdout)

    def test_raw_strings(self):
        self.assertEqual(self.counts(['let a = #"Ask "agent" now"#', 'let b = ##"x "# engine"##']), 2)

    def test_escaped_newline_separates_words(self):
        self.assertEqual(self.counts([r'let a = "Hello\ntask"']), 1)

    def test_removed_literal_asks_for_update_then_passes(self):
        self.write("A.swift", ['let a = "one task"', 'let c = "two tasks"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("A.swift", ['let a = "one task"'])
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--update", result.stdout)
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.run_script().returncode, 0)

    def test_update_refuses_an_increase(self):
        self.write("A.swift", ['let a = "one task"'])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("A.swift", ['let a = "one task"', 'let c = "two tasks"'])
        before = self.baseline_text()
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.baseline_text(), before)

    def test_baseline_round_trips(self):
        self.write("A.swift", ['let a = "one task"', 'let b = "an engine"'])
        self.write("B.swift", ['let c = "Background"'], SECOND)
        self.assertEqual(self.run_script("--update").returncode, 0)
        first = self.baseline_text()
        self.assertEqual(
            first,
            "2 apps/vera-mac/Sources/Vera/A.swift\n1 prototypes/assistant-ui/Sources/VeraAssistantUI/B.swift\n",
        )
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.assertEqual(self.baseline_text(), first)

    def test_new_file_in_a_second_root_fails(self):
        self.write("A.swift", ["let a = 1"])
        self.assertEqual(self.run_script("--update").returncode, 0)
        self.write("B.swift", ['let b = "Untitled task"'], SECOND)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VeraAssistantUI/B.swift:1", result.stdout)

    def test_list_prints_every_hit_without_touching_the_baseline(self):
        self.write("A.swift", ['let a = "fine"', 'let b = "Stop this task"', 'let c = "worker_type"', 'let d = "The engine"'])
        result = self.run_script("--list")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            result.stdout.splitlines(),
            ['apps/vera-mac/Sources/Vera/A.swift:2: "Stop this task"', 'apps/vera-mac/Sources/Vera/A.swift:4: "The engine"'],
        )
        self.assertFalse(os.path.exists(self.baseline))

    def test_unscanned_local_package_fails(self):
        manifest = os.path.join(self.root, "apps", "vera-mac", "Package.swift")
        with open(manifest, "w") as handle:
            handle.write('dependencies: [.package(path: "../../prototypes/other")]\n')
        self.write("A.swift", ["let a = 1"])
        result = self.run_script("--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("prototypes/other", result.stdout)


if __name__ == "__main__":
    unittest.main()
