#!/usr/bin/env python3
import argparse
import os
import re
import sys

ROOTS = [
    "apps/vera-mac/Sources/Vera",
    "prototypes/assistant-ui/Sources/VeraAssistantUI",
]
PACKAGE_MANIFEST = "apps/vera-mac/Package.swift"
LOCAL_PACKAGE = re.compile(r'\.package\(\s*path:\s*"([^"]+)"')
NAME = re.compile(r"\bVera\b")


class Tokenizer:
    def __init__(self, text):
        self.text = text
        self.size = len(text)
        self.line = 1
        self.literals = []

    def newline_count(self, start, end):
        self.line += self.text.count("\n", start, end)

    def code(self, i, nested):
        text = self.text
        depth = 0
        while i < self.size:
            char = text[i]
            if char == "\n":
                self.line += 1
                i += 1
            elif text.startswith("//", i):
                end = text.find("\n", i)
                i = self.size if end < 0 else end
            elif text.startswith("/*", i):
                i = self.block_comment(i)
            elif char == "#":
                pounds = 0
                while i + pounds < self.size and text[i + pounds] == "#":
                    pounds += 1
                if i + pounds < self.size and text[i + pounds] == '"':
                    i = self.string(i + pounds, pounds)
                else:
                    i += pounds
            elif char == '"':
                i = self.string(i, 0)
            elif char == "(":
                depth += 1
                i += 1
            elif char == ")":
                if nested and depth == 0:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return i

    def block_comment(self, i):
        text = self.text
        level = 0
        while i < self.size:
            if text.startswith("/*", i):
                level += 1
                i += 2
            elif text.startswith("*/", i):
                level -= 1
                i += 2
                if level == 0:
                    return i
            else:
                if text[i] == "\n":
                    self.line += 1
                i += 1
        return i

    def string(self, i, pounds):
        text = self.text
        start_line = self.line
        multiline = text.startswith('"""', i)
        quotes = '"""' if multiline else '"'
        closing = quotes + "#" * pounds
        escape = "\\" + "#" * pounds
        i += len(quotes)
        body = []
        while i < self.size:
            if text.startswith(closing, i):
                i += len(closing)
                break
            char = text[i]
            if text.startswith(escape, i):
                after = i + len(escape)
                if after < self.size and text[after] == "(":
                    body.append("\0")
                    i = self.code(after + 1, True)
                    continue
                if after < self.size:
                    body.append(text[after])
                    if text[after] == "\n":
                        self.line += 1
                i = after + 1
                continue
            if char == "\n":
                if not multiline:
                    break
                self.line += 1
            body.append(char)
            i += 1
        self.literals.append((start_line, "".join(body)))
        return i


def string_literals(text):
    tokenizer = Tokenizer(text)
    tokenizer.code(0, False)
    return tokenizer.literals


def local_package_roots(root):
    manifest = os.path.join(root, PACKAGE_MANIFEST)
    if not os.path.exists(manifest):
        return []
    with open(manifest, encoding="utf-8") as handle:
        text = handle.read()
    base = os.path.dirname(manifest)
    found = []
    for declared in LOCAL_PACKAGE.findall(text):
        resolved = os.path.normpath(os.path.join(base, declared))
        found.append(os.path.relpath(resolved, root).replace(os.sep, "/"))
    return found


def uncovered_packages(root):
    missing = []
    for package in local_package_roots(root):
        if not any(r == package or r.startswith(package + "/") for r in ROOTS):
            missing.append(package)
    return missing


def scan(root):
    found = {}
    for source_root in ROOTS:
        base = os.path.join(root, source_root)
        for folder, _, names in os.walk(base):
            for name in sorted(names):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(folder, name)
                relative = os.path.relpath(path, root).replace(os.sep, "/")
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                hits = []
                for number, body in sorted(string_literals(text)):
                    if NAME.search(body):
                        hits.append((number, body.replace("\0", "...").split("\n")[0][:100]))
                if hits:
                    found[relative] = hits
    return found


def read_baseline(path):
    counts = {}
    if not os.path.exists(path):
        return counts
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            count, _, relative = line.partition(" ")
            counts[relative] = int(count)
    return counts


def write_baseline(path, found):
    lines = ["%d %s\n" % (len(found[key]), key) for key in sorted(found)]
    with open(path, "w", encoding="utf-8") as handle:
        handle.writelines(lines)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=os.path.dirname(here))
    parser.add_argument("--baseline")
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    baseline_path = args.baseline or os.path.join(root, "scripts", "name-ratchet-baseline.txt")
    missing = uncovered_packages(root)
    if missing:
        for package in missing:
            print("%s is a local package the app links but the ratchet does not scan it" % package)
        print("name-ratchet: add the package's source folder to ROOTS in scripts/name-ratchet.py.")
        return 1
    found = scan(root)
    baseline = read_baseline(baseline_path)

    raised = [key for key in sorted(found) if len(found[key]) > baseline.get(key, 0)]
    lowered = [key for key in sorted(set(found) | set(baseline)) if len(found.get(key, [])) < baseline.get(key, 0)]

    if args.update:
        if raised and os.path.exists(baseline_path):
            for key in raised:
                print("%s: %d string literals say Vera, baseline allows %d" % (key, len(found[key]), baseline.get(key, 0)))
                for number, literal in found[key]:
                    print("  %s:%d: \"%s\"" % (key, number, literal))
            print("name-ratchet: refusing to raise the baseline. Name the companion through the companion name value instead.")
            return 1
        write_baseline(baseline_path, found)
        print("name-ratchet: baseline updated")
        return 0

    if raised:
        for key in raised:
            print("%s: %d string literals say Vera, baseline allows %d" % (key, len(found[key]), baseline.get(key, 0)))
            for number, literal in found[key]:
                print("  %s:%d: \"%s\"" % (key, number, literal))
        print("name-ratchet: new text must name the companion through the companion name value, not a literal name.")
        return 1
    if lowered:
        for key in lowered:
            print("%s: %d string literals say Vera, baseline has %d" % (key, len(found.get(key, [])), baseline[key]))
        print("name-ratchet: the count went down. Run scripts/name-ratchet.py --update so the baseline drops in the same change.")
        return 1
    print("name-ratchet: ok (%d literals in %d files)" % (sum(len(v) for v in found.values()), len(found)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
