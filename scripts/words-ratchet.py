#!/usr/bin/env python3
import argparse
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("name_ratchet", os.path.join(HERE, "name-ratchet.py"))
name_ratchet = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(name_ratchet)

ROOTS = name_ratchet.ROOTS
INTERPOLATION = name_ratchet.INTERPOLATION
WORDS = ("task", "tasks", "background", "worker", "workers", "agent", "agents", "engine", "engines")
WORD = re.compile(r"(?<![A-Za-z0-9_])(?:" + "|".join(WORDS) + r")(?![A-Za-z0-9_])", re.IGNORECASE)
WINDOW = 160


def flatten(body):
    return body.replace(INTERPOLATION, "...").replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")


def excerpt(body):
    text = flatten(body)
    if len(text) <= WINDOW:
        return text
    match = WORD.search(text)
    start = max(0, (match.start() if match else 0) - WINDOW // 2)
    end = min(len(text), start + WINDOW)
    start = max(0, end - WINDOW)
    return ("..." if start > 0 else "") + text[start:end] + ("..." if end < len(text) else "")


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
                for number, body in sorted(name_ratchet.string_literals(text)):
                    if WORD.search(body.replace(INTERPOLATION, " ")):
                        hits.append((number, body))
                if hits:
                    found[relative] = hits
    return found


def report(key, hits, allowed, verb):
    print("%s: %d string literals use a listed word, baseline %s %d" % (key, len(hits), verb, allowed))
    for number, body in hits:
        print("  %s:%d: \"%s\"" % (key, number, excerpt(body)))


def main():
    parser = argparse.ArgumentParser(
        description="Counts Swift string literals that use task, background, worker, agent or engine as a whole word "
        "and compares them with a baseline. Letters, digits and underscores join a word, so identifiers such as "
        "taskID or worker_type do not count. Every other character, hyphens and dots included, separates words."
    )
    parser.add_argument("--root", default=os.path.dirname(HERE))
    parser.add_argument("--baseline")
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    baseline_path = args.baseline or os.path.join(root, "scripts", "words-ratchet-baseline.txt")
    found = scan(root)

    if args.list:
        for key in sorted(found):
            for number, body in found[key]:
                print("%s:%d: \"%s\"" % (key, number, excerpt(body)))
        return 0

    missing, unreadable = name_ratchet.uncovered_packages(root)
    if missing or unreadable:
        for package in missing:
            print("%s is a local package the app links but the ratchet does not scan it" % package)
        for number in unreadable:
            print("%s:%d: a local package path that is not a plain string can't be checked" % (name_ratchet.PACKAGE_MANIFEST, number))
        print("words-ratchet: add the package's source folder to ROOTS in scripts/name-ratchet.py and spell its path as a string.")
        return 1

    baseline = name_ratchet.read_baseline(baseline_path)
    raised = [key for key in sorted(found) if len(found[key]) > baseline.get(key, 0)]
    lowered = [key for key in sorted(set(found) | set(baseline)) if len(found.get(key, [])) < baseline.get(key, 0)]

    if args.update:
        if raised and os.path.exists(baseline_path):
            for key in raised:
                report(key, found[key], baseline.get(key, 0), "allows")
            print("words-ratchet: refusing to raise the baseline. Say what the person gets in plain words instead.")
            return 1
        name_ratchet.write_baseline(baseline_path, found)
        print("words-ratchet: baseline updated")
        return 0

    if raised:
        for key in raised:
            report(key, found[key], baseline.get(key, 0), "allows")
        print("words-ratchet: text a person reads must not say task, background, worker, agent or engine.")
        return 1
    if lowered:
        for key in lowered:
            print("%s: %d string literals use a listed word, baseline has %d" % (key, len(found.get(key, [])), baseline[key]))
        print("words-ratchet: the count went down. Run scripts/words-ratchet.py --update so the baseline drops in the same change.")
        return 1
    print("words-ratchet: ok (%d literals in %d files)" % (sum(len(v) for v in found.values()), len(found)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
