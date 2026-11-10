#!/usr/bin/env python3
import argparse
import os
import re
import sys

SOURCE_DIR = os.path.join("apps", "vera-mac", "Sources", "Vera")
LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')
NAME = re.compile(r"\bVera\b")


def scan(root):
    found = {}
    base = os.path.join(root, SOURCE_DIR)
    for folder, _, names in os.walk(base):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            hits = []
            with open(path, encoding="utf-8", errors="replace") as handle:
                for number, line in enumerate(handle, 1):
                    for literal in LITERAL.findall(line):
                        if NAME.search(literal):
                            hits.append((number, literal))
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
    found = scan(root)
    baseline = read_baseline(baseline_path)

    raised = [key for key in sorted(found) if len(found[key]) > baseline.get(key, 0)]
    lowered = [key for key in sorted(set(found) | set(baseline)) if len(found.get(key, [])) < baseline.get(key, 0)]

    if args.update:
        if raised and os.path.exists(baseline_path):
            for key in raised:
                print("%s: %d string literals say Vera, baseline allows %d" % (key, len(found[key]), baseline.get(key, 0)))
                for number, literal in found[key]:
                    print("  %s:%d: %s" % (key, number, literal))
            print("name-ratchet: refusing to raise the baseline. Name the companion through the companion name value instead.")
            return 1
        write_baseline(baseline_path, found)
        print("name-ratchet: baseline updated")
        return 0

    if raised:
        for key in raised:
            print("%s: %d string literals say Vera, baseline allows %d" % (key, len(found[key]), baseline.get(key, 0)))
            for number, literal in found[key]:
                print("  %s:%d: %s" % (key, number, literal))
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
