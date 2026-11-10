from __future__ import annotations

import importlib.metadata
from collections.abc import Callable
from pathlib import Path

from packaging.requirements import InvalidRequirement, Requirement
from packaging.utils import NormalizedName, canonicalize_name
from packaging.version import InvalidVersion, Version

API_DIR = Path(__file__).resolve().parent.parent
RUNTIME_IN = API_DIR / "requirements.in"
DEV_IN = API_DIR / "requirements-dev.in"
RUNTIME_TXT = API_DIR / "requirements.txt"
DEV_TXT = API_DIR / "requirements-dev.txt"

INSTALL_HINT = (
    "run `pip install -r requirements.txt -r requirements-dev.txt` from services/vera-api"
)

Pins = dict[NormalizedName, Requirement]
VersionLookup = Callable[[str], str | None]


def _meaningful_lines(text: str) -> list[str]:
    lines: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if line:
            lines.append(line)
    return lines


def parse_compiled(text: str) -> tuple[Pins, list[str]]:
    pins: Pins = {}
    problems: list[str] = []
    for line in _meaningful_lines(text):
        if line.startswith("-"):
            problems.append(f"option line is not allowed: {line}")
            continue
        try:
            requirement = Requirement(line)
        except InvalidRequirement as error:
            problems.append(f"unparseable line: {line} ({error})")
            continue
        specifiers = list(requirement.specifier)
        if len(specifiers) != 1 or specifiers[0].operator != "==" or "*" in specifiers[0].version:
            problems.append(f"not pinned to one exact version: {line}")
            continue
        pins[canonicalize_name(requirement.name)] = requirement
    return pins, problems


def parse_direct(text: str) -> list[NormalizedName]:
    names: list[NormalizedName] = []
    for line in _meaningful_lines(text):
        if line.startswith("-"):
            continue
        names.append(canonicalize_name(Requirement(line).name))
    return names


def pinned_version(requirement: Requirement) -> str:
    return next(iter(requirement.specifier)).version


def missing_direct(direct: list[NormalizedName], pins: Pins) -> list[NormalizedName]:
    return [name for name in direct if name not in pins]


def shared_disagreements(first: Pins, second: Pins) -> list[str]:
    problems: list[str] = []
    for name in sorted(first.keys() & second.keys()):
        a = pinned_version(first[name])
        b = pinned_version(second[name])
        if Version(a) != Version(b):
            problems.append(f"{name}: {a} in one file, {b} in the other")
    return problems


def installed_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def environment_mismatches(pins: Pins, lookup: VersionLookup) -> list[str]:
    problems: list[str] = []
    for name in sorted(pins):
        requirement = pins[name]
        if requirement.marker is not None and not requirement.marker.evaluate():
            continue
        wanted = pinned_version(requirement)
        found = lookup(name)
        if found is None:
            problems.append(f"{name}: pinned {wanted}, not installed")
            continue
        try:
            matches = Version(found) == Version(wanted)
        except InvalidVersion:
            matches = found == wanted
        if not matches:
            problems.append(f"{name}: pinned {wanted}, installed {found}")
    return problems


def _load(path: Path) -> Pins:
    pins, problems = parse_compiled(path.read_text())
    assert not problems, f"{path.name}: " + "; ".join(problems)
    return pins


def test_runtime_file_is_fully_pinned() -> None:
    _, problems = parse_compiled(RUNTIME_TXT.read_text())
    assert problems == []


def test_dev_file_is_fully_pinned() -> None:
    _, problems = parse_compiled(DEV_TXT.read_text())
    assert problems == []


def test_runtime_direct_dependencies_are_compiled() -> None:
    assert missing_direct(parse_direct(RUNTIME_IN.read_text()), _load(RUNTIME_TXT)) == []


def test_dev_direct_dependencies_are_compiled() -> None:
    assert missing_direct(parse_direct(DEV_IN.read_text()), _load(DEV_TXT)) == []


def test_runtime_and_dev_agree_on_shared_packages() -> None:
    assert shared_disagreements(_load(RUNTIME_TXT), _load(DEV_TXT)) == []


def test_environment_matches_pins() -> None:
    problems = environment_mismatches({**_load(RUNTIME_TXT), **_load(DEV_TXT)}, installed_version)
    assert not problems, (
        "installed packages do not match the pinned versions:\n  "
        + "\n  ".join(problems)
        + f"\n{INSTALL_HINT}"
    )


def _lookup(table: dict[str, str]) -> VersionLookup:
    def find(name: str) -> str | None:
        return table.get(name)

    return find


def test_unpinned_line_is_reported() -> None:
    pins, problems = parse_compiled("fastapi==1.0\nhttpx>=0.28\nrich\n")
    assert list(pins) == ["fastapi"]
    assert len(problems) == 2
    assert "httpx>=0.28" in problems[0]
    assert "rich" in problems[1]


def test_range_with_exact_pin_is_reported() -> None:
    _, problems = parse_compiled("httpx==0.28.1,<1\n")
    assert len(problems) == 1


def test_wildcard_pin_is_reported() -> None:
    pins, problems = parse_compiled("colorama==0.4.* ; sys_platform == 'win32'\n")
    assert pins == {}
    assert len(problems) == 1
    assert "colorama==0.4.*" in problems[0]


def test_option_line_is_reported() -> None:
    _, problems = parse_compiled("-c other.txt\n--index-url https://example.invalid\nfastapi==1.0\n")
    assert len(problems) == 2
    assert all("option line" in problem for problem in problems)


def test_direct_parser_skips_constraints_and_normalizes() -> None:
    names = parse_direct("-c requirements.txt\nuvicorn[standard]\nPython_Multipart\nplaywright==1.58.0\n")
    assert names == ["uvicorn", "python-multipart", "playwright"]


def test_missing_direct_dependency_is_reported() -> None:
    pins, _ = parse_compiled("fastapi==1.0\n")
    assert missing_direct(parse_direct("fastapi\npypdf\n"), pins) == ["pypdf"]


def test_shared_disagreement_is_reported() -> None:
    first, _ = parse_compiled("anyio==4.0\nidna==3.0\n")
    second, _ = parse_compiled("anyio==4.1\nidna==3.0\n")
    assert shared_disagreements(first, second) == ["anyio: 4.0 in one file, 4.1 in the other"]


def test_marker_excluding_this_platform_is_skipped() -> None:
    pins, _ = parse_compiled("ghostpkg==1.0 ; sys_platform == 'no-such-platform'\n")
    assert environment_mismatches(pins, _lookup({})) == []


def test_marker_matching_this_platform_is_checked() -> None:
    pins, _ = parse_compiled("realpkg==1.0 ; sys_platform != 'no-such-platform'\n")
    assert environment_mismatches(pins, _lookup({})) == ["realpkg: pinned 1.0, not installed"]


def test_mismatched_version_names_both() -> None:
    pins, _ = parse_compiled("fastapi==0.162.2\n")
    assert environment_mismatches(pins, _lookup({"fastapi": "0.135.2"})) == [
        "fastapi: pinned 0.162.2, installed 0.135.2"
    ]


def test_missing_package_is_reported() -> None:
    pins, _ = parse_compiled("pypdf==7.0.0\n")
    assert environment_mismatches(pins, _lookup({})) == ["pypdf: pinned 7.0.0, not installed"]


def test_equivalent_version_spellings_match() -> None:
    pins, _ = parse_compiled("pytest-asyncio==1.4.1.post1\n")
    assert environment_mismatches(pins, _lookup({"pytest-asyncio": "1.4.1-post1"})) == []
