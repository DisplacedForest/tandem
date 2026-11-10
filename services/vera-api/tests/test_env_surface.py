"""Config-surface completeness guard — every env var vera-api reads must be discoverable
in the repo-root .env.example (active `NAME=` or documented `#NAME=` line), or carry an
explicit exemption here with a reason. Fails the moment a new os.environ/os.getenv read
lands without documentation, so the surface can never silently drift again.
Run: python3 -m pytest tests/test_env_surface.py
"""
import ast
import functools
import os
import pathlib
import re
import subprocess
from collections.abc import Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field

API_ROOT = pathlib.Path(__file__).resolve().parent.parent          # services/vera-api
ENV_EXAMPLE = API_ROOT.parent.parent / ".env.example"              # repo root
REPO_ROOT = API_ROOT.parent.parent
SERVER_DIR = "services/vera-api"

# Vars deliberately NOT in .env.example — every entry needs a reason.
EXEMPT: dict[str, str] = {
    "VERA_VERSION": "image-build fallback for /version when no VERSION file is baked; not deployment config",
}

DOCUMENTED_IN_PROSE: dict[str, str] = {
    "HOME_EVENTS_ENABLED": "legacy kill switch that can only force home modeling off; named in the Home Assistant "
                           "prose beside the feature it overrides rather than as an entry",
    "MEDIA_CURATION_ENABLED": "legacy kill switch that can only force media curation off; named in the Media "
                              "prose beside the feature it overrides rather than as an entry",
}

DOCUMENTED_NOT_READ: dict[str, str] = {
    "MEDIA_CURATION_TASTE": "seeded by a media vein's taste option when its definition declares this key as its env seed",
}

DYNAMIC_KEY_PATTERNS: dict[str, str] = {
    r"SCHEDULE_[A-Z0-9_]+": "the scheduler builds SCHEDULE_<JOB> and SCHEDULE_<JOB>_ENABLED from each job id",
}

LITERAL_TABLES: dict[tuple[str, str], str] = {
    ("services/vera-api/data_paths.py", "STORE_PATHS"): "keys",
    ("services/vera-api/routers/integrations_registry.py", "_FEATURE_KILL_SWITCH"): "values",
}

TEST_ONLY_SWIFT_NAME_PARTS: tuple[str, ...] = ("Selftest", "SelfTest", "Fixture", "Shot", "Tests")
SWIFT_ENVIRONMENT_NAMES: tuple[str, ...] = ("env", "environment")
OUTSIDE_PYTHON_ROOTS: tuple[str, ...] = ("scripts/", "apps/vera-mac/scripts/")
OUTSIDE_SHELL_ROOTS: tuple[str, ...] = ("scripts/", "apps/vera-mac/scripts/")
OUTSIDE_SWIFT_ROOTS: tuple[str, ...] = ("apps/vera-mac/Sources/", "apps/vera-mac/scripts/")
COMPOSE_FILE = "docker-compose.yml"

ENV_KEY = re.compile(r"^[A-Z][A-Z0-9_]+$")
_KEY = r"[A-Z][A-Z0-9_]+"
_COMPAT_FUNCS = ("read", "is_set")
_ENVIRON_CALLS = ("environ.get", "environ.setdefault", "environ.pop", "os.getenv")
_SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)
_FUNCS = (ast.FunctionDef, ast.AsyncFunctionDef)

Spec = tuple[int | None, str]
Exports = dict[str, set[Spec]]


@dataclass(frozen=True)
class _Imported:
    module: str
    level: int
    name: str


Binding = ast.AST | _Imported | None


@dataclass
class _Frame:
    scope: ast.AST
    params: set[str]
    assigned: dict[str, list[Binding]] = field(default_factory=dict)


def _params(scope: ast.AST) -> set[str]:
    if not isinstance(scope, (*_FUNCS, ast.Lambda)):
        return set()
    a = scope.args
    names = [x.arg for x in a.posonlyargs + a.args + a.kwonlyargs]
    names += [x.arg for x in (a.vararg, a.kwarg) if x is not None]
    return set(names)


def _outer_parts(node: ast.AST) -> list[ast.AST]:
    parts: list[ast.AST] = list(getattr(node, "decorator_list", [])) + list(getattr(node, "type_params", []))
    if isinstance(node, ast.ClassDef):
        parts += node.bases + node.keywords
    elif isinstance(node, (*_FUNCS, ast.Lambda)):
        parts.append(node.args)
        if not isinstance(node, ast.Lambda) and node.returns is not None:
            parts.append(node.returns)
    return parts


def _own_nodes(scope: ast.AST) -> list[ast.AST]:
    stack: list[ast.AST] = [scope.body] if isinstance(scope, ast.Lambda) else list(scope.body)
    out: list[ast.AST] = []
    while stack:
        node = stack.pop()
        out.append(node)
        stack.extend(_outer_parts(node) if isinstance(node, _SCOPES) else ast.iter_child_nodes(node))
    return out


def _frame(scope: ast.AST, own: list[ast.AST]) -> _Frame:
    frame = _Frame(scope, _params(scope))
    direct: dict[int, ast.expr] = {}
    for node in own:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    direct[id(target)] = node.value
        elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and isinstance(node.target, ast.Name) \
                and node.value is not None:
            direct[id(node.target)] = node.value
    for node in own:
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            frame.assigned.setdefault(node.id, []).append(direct.get(id(node)))
        elif isinstance(node, (*_FUNCS, ast.ClassDef)):
            frame.assigned.setdefault(node.name, []).append(node)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                bound = alias.asname or alias.name.split(".")[0]
                module = alias.name if alias.asname else bound
                frame.assigned.setdefault(bound, []).append(_Imported(module, 0, ""))
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                frame.assigned.setdefault(alias.asname or alias.name, []).append(
                    _Imported(node.module or "", node.level, alias.name))
    return frame


def _walk_scopes(tree: ast.Module) -> Iterator[tuple[list[ast.AST], list[_Frame]]]:
    pending: list[tuple[ast.AST, list[_Frame]]] = [(tree, [])]
    while pending:
        scope, outer = pending.pop()
        own = _own_nodes(scope)
        chain = [_frame(scope, own)] + outer
        yield own, chain
        visible = [f for f in chain if not isinstance(f.scope, ast.ClassDef)]
        pending.extend((node, visible) for node in own if isinstance(node, _SCOPES))


def _binding(name: str, chain: list[_Frame]) -> _Frame | None:
    for frame in chain:
        if name in frame.params or name in frame.assigned:
            return frame
    return None


def _resolve(name: str, chain: list[_Frame]) -> list[Binding]:
    frame = _binding(name, chain)
    if frame is None or name in frame.params:
        return []
    return frame.assigned[name]


def _literals(node: ast.AST | None, chain: list[_Frame]) -> set[str]:
    if isinstance(node, ast.Constant):
        return {node.value} if isinstance(node.value, str) else set()
    if isinstance(node, ast.IfExp):
        body, orelse = _literals(node.body, chain), _literals(node.orelse, chain)
        return body | orelse if body and orelse else set()
    if isinstance(node, ast.Name) and chain:
        bindings = _resolve(node.id, chain)
        if not bindings or not all(isinstance(b, ast.expr) for b in bindings):
            return set()
        parts = [_literals(b, []) for b in bindings]
        return set().union(*parts) if all(parts) else set()
    return set()


def _is_compat(module: str) -> bool:
    return module.split(".")[-1] == "env_compat"


def _compat_module(value: ast.expr, chain: list[_Frame]) -> bool:
    if isinstance(value, ast.Attribute):
        return value.attr == "env_compat"
    if not isinstance(value, ast.Name):
        return False
    bindings = _resolve(value.id, chain)
    return bool(bindings) and all(
        isinstance(b, _Imported) and (b.name == "env_compat" or (not b.name and _is_compat(b.module)))
        for b in bindings)


def _compat_function(bindings: list[Binding]) -> bool:
    return bool(bindings) and all(
        isinstance(b, _Imported) and _is_compat(b.module) and b.name in _COMPAT_FUNCS for b in bindings)


def _import_target(rel: str, module: str, level: int) -> str:
    module_path = module.replace(".", "/") + ".py"
    if not level:
        return pathlib.PurePosixPath(module_path).as_posix()
    base = pathlib.PurePosixPath(rel).parent
    for _ in range(level - 1):
        base = base.parent
    return (base / module_path).as_posix()


def _helper_specs(bindings: list[Binding], rel: str, local: Mapping[int, set[Spec]],
                  exports: Mapping[str, Exports]) -> set[Spec]:
    if not bindings:
        return set()
    if all(isinstance(b, _FUNCS) and id(b) in local for b in bindings):
        return set().union(*(local[id(b)] for b in bindings))
    if len(bindings) == 1 and isinstance(bindings[0], _Imported) and bindings[0].name and bindings[0].module:
        b = bindings[0]
        return set(exports.get(_import_target(rel, b.module, b.level), {}).get(b.name, set()))
    return set()


def _arg(call: ast.Call, index: int | None, keyword: str) -> ast.expr | None:
    if index is not None and len(call.args) > index \
            and not any(isinstance(a, ast.Starred) for a in call.args[:index + 1]):
        return call.args[index]
    return next((k.value for k in call.keywords if k.arg == keyword), None)


def _key_args(node: ast.AST, chain: list[_Frame], rel: str, local: Mapping[int, set[Spec]],
              exports: Mapping[str, Exports]) -> list[ast.expr]:
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) \
            and "environ" in ast.unparse(node.value):
        return [node.slice]
    if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.In, ast.NotIn)) \
            and ast.unparse(node.comparators[0]).endswith("environ"):
        return [node.left]
    if not isinstance(node, ast.Call):
        return []
    func = node.func
    keyword = None
    if isinstance(func, ast.Attribute):
        if ast.unparse(func).endswith(_ENVIRON_CALLS):
            keyword = "key"
        elif func.attr in _COMPAT_FUNCS and _compat_module(func.value, chain):
            keyword = "name"
    elif isinstance(func, ast.Name):
        bindings = _resolve(func.id, chain)
        if _compat_function(bindings):
            keyword = "name"
        else:
            specs = _helper_specs(bindings, rel, local, exports)
            found = (_arg(node, index, param) for index, param in sorted(specs, key=str))
            return [a for a in found if a is not None]
    if keyword is None:
        return []
    found_arg = _arg(node, 0, keyword)
    return [found_arg] if found_arg is not None else []


def _env_field_keys(node: ast.Dict) -> set[str]:
    fields = {k.value: v for k, v in zip(node.keys, node.values)
              if isinstance(k, ast.Constant) and isinstance(k.value, str)}
    env = fields.get("env")
    if not {"id", "label"} <= set(fields) or not isinstance(env, ast.Constant):
        return set()
    return {env.value} if isinstance(env.value, str) and ENV_KEY.match(env.value) else set()


def _spec(func: ast.FunctionDef | ast.AsyncFunctionDef, param: str) -> Spec:
    positional = [a.arg for a in func.args.posonlyargs + func.args.args]
    return (positional.index(param) if param in positional else None, param)


def _scan(tree: ast.Module, rel: str, local: Mapping[int, set[Spec]],
          exports: Mapping[str, Exports]) -> tuple[set[str], dict[int, set[Spec]]]:
    keys: set[str] = set()
    found: dict[int, set[Spec]] = {}
    for own, chain in _walk_scopes(tree):
        for node in own:
            if isinstance(node, ast.Dict):
                keys |= _env_field_keys(node)
            for arg in _key_args(node, chain, rel, local, exports):
                if isinstance(arg, ast.Name):
                    frame = _binding(arg.id, chain)
                    if frame is not None and arg.id in frame.params:
                        if isinstance(frame.scope, _FUNCS):
                            found.setdefault(id(frame.scope), set()).add(_spec(frame.scope, arg.id))
                        continue
                keys |= _literals(arg, chain)
    return keys, found


def _analyze(tree: ast.Module, rel: str, exports: Mapping[str, Exports]) -> tuple[set[str], Exports]:
    local: dict[int, set[Spec]] = {}
    while True:
        keys, found = _scan(tree, rel, local, exports)
        grown = False
        for key, specs in found.items():
            if not specs <= local.get(key, set()):
                local.setdefault(key, set()).update(specs)
                grown = True
        if not grown:
            exported = {n.name: local[id(n)] for n in tree.body if isinstance(n, _FUNCS) and id(n) in local}
            return keys, exported


def collect_from_sources(sources: Mapping[str, str]) -> dict[str, str]:
    trees: dict[str, ast.Module] = {}
    for rel, source in sources.items():
        try:
            trees[rel] = ast.parse(source)
        except SyntaxError:
            continue
    first = {rel: _analyze(tree, rel, {}) for rel, tree in trees.items()}
    exports = {rel: exported for rel, (_, exported) in first.items()}
    out: dict[str, str] = {}
    for rel in sorted(trees):
        keys = _analyze(trees[rel], rel, exports)[0]
        for key in sorted(keys):
            out.setdefault(key, rel)
    return out


def collect_from_source(source: str) -> set[str]:
    return set(collect_from_sources({"module.py": source}))


def tracked_files(repo_root: pathlib.Path) -> list[str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        proc = subprocess.run(["git", "ls-files", "-z"], cwd=repo_root, env=env,
                              capture_output=True, check=False)
    except OSError as exc:
        raise AssertionError(f"the env surface guard needs git to list tracked files: {exc}") from exc
    assert proc.returncode == 0, (
        f"the env surface guard needs a git work tree at {repo_root} to list tracked files: "
        + proc.stderr.decode(errors="replace").strip())
    return sorted(p for p in proc.stdout.decode().split("\0") if p)


@functools.lru_cache(maxsize=1)
def _repo_files() -> tuple[str, ...]:
    return tuple(tracked_files(REPO_ROOT))


def _under(files: Iterable[str], prefix: str) -> list[str]:
    stem = prefix.rstrip("/") + "/"
    return [f[len(stem):] for f in files if f.startswith(stem)]


def _python_test_file(rel: str) -> bool:
    path = pathlib.PurePosixPath(rel)
    return bool({"tests", "test"} & set(path.parts)) or path.name.startswith("test_") \
        or path.name == "conftest.py"


def collect_env_reads(root: pathlib.Path, files: Iterable[str]) -> dict[str, str]:
    sources: dict[str, str] = {}
    for rel in sorted(files):
        path = root / rel
        if rel.endswith(".py") and "__pycache__" not in rel.split("/") and not _python_test_file(rel) \
                and path.is_file():
            sources[rel] = path.read_text(errors="ignore")
    return collect_from_sources(sources)


def literal_table_keys(repo_root: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for (rel, name), side in LITERAL_TABLES.items():
        path = repo_root / rel
        if not path.is_file():
            continue
        for node in ast.parse(path.read_text()).body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
                table = ast.literal_eval(node.value)
                for key in (table.keys() if side == "keys" else table.values()):
                    out.setdefault(key, rel)
    return out


def server_reads(repo_root: pathlib.Path, files: Sequence[str]) -> dict[str, str]:
    reads = collect_env_reads(repo_root / SERVER_DIR, _under(files, SERVER_DIR))
    for key, rel in literal_table_keys(repo_root).items():
        reads.setdefault(key, pathlib.PurePosixPath(rel).relative_to(SERVER_DIR).as_posix())
    return reads


def documented_keys(env_example: pathlib.Path) -> set[str]:
    return set(re.findall(r"^\s*#?([A-Z][A-Z0-9_]+)=", env_example.read_text(), re.M))


def undocumented_reads(reads: Mapping[str, str], documented: set[str],
                       exempt: Mapping[str, str]) -> dict[str, str]:
    return {name: where for name, where in sorted(reads.items())
            if name not in documented and name not in exempt}


def _strip_swift_comments(text: str) -> str:
    out: list[str] = []
    i, n = 0, len(text)
    quote: str | None = None
    while i < n:
        if quote:
            if text.startswith(quote, i):
                out.append(quote)
                i += len(quote)
                quote = None
            elif text[i] == "\\" and i + 1 < n:
                out.append(text[i:i + 2])
                i += 2
            else:
                out.append(text[i])
                i += 1
        elif text.startswith('"""', i) or text[i] == '"':
            quote = '"""' if text.startswith('"""', i) else '"'
            out.append(quote)
            i += len(quote)
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _swift_test_file(rel: str) -> bool:
    stem = pathlib.PurePosixPath(rel).stem
    return any(part in stem for part in TEST_ONLY_SWIFT_NAME_PARTS)


def swift_reads(text: str) -> set[str]:
    code = _strip_swift_comments(text)
    holders = "|".join(re.escape(n) for n in SWIFT_ENVIRONMENT_NAMES)
    holder = rf"(?:ProcessInfo\.processInfo\.environment|\b(?:{holders}))"
    keys = set(re.findall(rf'{holder}\[\s*"({_KEY})"\s*\]', code))
    for match in re.finditer(r"\bfunc\s+(\w+)\s*\(\s*_\s+(\w+)\s*:\s*String\b", code):
        start = code.find("{", match.end())
        if start < 0:
            continue
        depth, end = 0, start
        while end < len(code):
            depth += {"{": 1, "}": -1}.get(code[end], 0)
            if depth == 0:
                break
            end += 1
        if re.search(rf"{holder}\[\s*{re.escape(match.group(2))}\s*\]", code[start:end]):
            keys |= set(re.findall(rf'\b{re.escape(match.group(1))}\(\s*"({_KEY})"', code))
    return keys


def _shell_file(rel: str, text: str) -> bool:
    name = pathlib.PurePosixPath(rel).name
    if name.startswith(("test-", "test_")):
        return False
    first = text.split("\n", 1)[0]
    return rel.endswith(".sh") or (first.startswith("#!") and re.search(r"\b(?:ba|z)?sh\b", first) is not None)


def shell_reads(text: str) -> set[str]:
    keys: set[str] = set()
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        keys |= set(re.findall(rf"\$\{{?({_KEY})\b", line))
    return keys


def compose_reads(text: str) -> set[str]:
    keys: set[str] = set()
    block_indent: int | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if block_indent is not None and indent <= block_indent:
            block_indent = None
        keys |= set(re.findall(rf"\$\{{?({_KEY})\b", line))
        if block_indent is not None:
            keys |= set(re.findall(rf"^-?\s*({_KEY})\s*(?:[=:]|$)", stripped))
        if stripped.rstrip(":") == "environment" and stripped.endswith(":"):
            block_indent = indent
    return keys


def reads_outside_server(repo_root: pathlib.Path, files: Sequence[str]) -> dict[str, str]:
    found: dict[str, str] = {}

    def add(keys: Iterable[str], where: str) -> None:
        for key in sorted(keys):
            found.setdefault(key, where)

    satellites = sorted({f.split("/")[1] for f in files
                         if f.startswith("services/") and f.count("/") >= 2} - {"vera-api"})
    python_roots = [f"services/{s}/" for s in satellites] + list(OUTSIDE_PYTHON_ROOTS)
    for root in python_roots:
        for key, rel in collect_env_reads(repo_root / root, _under(files, root)).items():
            found.setdefault(key, root + rel)
    for rel in files:
        path = repo_root / rel
        if not path.is_file():
            continue
        if rel.endswith(".swift") and rel.startswith(OUTSIDE_SWIFT_ROOTS) and not _swift_test_file(rel):
            add(swift_reads(path.read_text(errors="ignore")), rel)
        elif rel == COMPOSE_FILE:
            add(compose_reads(path.read_text(errors="ignore")), rel)
        elif rel.startswith(OUTSIDE_SHELL_ROOTS + tuple(f"services/{s}/" for s in satellites)) \
                and not rel.endswith(".py"):
            text = path.read_text(errors="ignore")
            if _shell_file(rel, text):
                add(shell_reads(text), rel)
    return found


def unread_documented(repo_root: pathlib.Path, files: Sequence[str], allow: Mapping[str, str]) -> list[str]:
    documented = documented_keys(repo_root / ".env.example")
    read = set(server_reads(repo_root, files)) | set(reads_outside_server(repo_root, files))
    return sorted(key for key in documented
                  if key not in read and key not in allow
                  and not any(re.fullmatch(p, key) for p in DYNAMIC_KEY_PATTERNS))


def test_every_env_read_is_documented():
    reads = server_reads(REPO_ROOT, _repo_files())
    assert reads, "extractor found no env reads — it is broken, not the codebase"
    undocumented = undocumented_reads(reads, documented_keys(ENV_EXAMPLE), {**EXEMPT, **DOCUMENTED_IN_PROSE})
    assert not undocumented, (
        "env vars read in code but missing from .env.example "
        "(add them there, or add an EXEMPT entry with a reason):\n"
        + "\n".join(f"  {n}  (first read in {w})" for n, w in undocumented.items()))


def test_exemptions_are_still_real():
    """An EXEMPT entry for a var nobody reads anymore is stale — prune it."""
    reads = server_reads(REPO_ROOT, _repo_files())
    stale = set(EXEMPT) - set(reads)
    assert not stale, f"stale exemptions (no longer read anywhere): {sorted(stale)}"


def test_prose_documented_keys_are_read_and_named() -> None:
    reads = server_reads(REPO_ROOT, _repo_files())
    text = ENV_EXAMPLE.read_text()
    documented = documented_keys(ENV_EXAMPLE)
    for key, reason in DOCUMENTED_IN_PROSE.items():
        assert reason.strip()
        assert key in reads, f"{key} is no longer read; drop it from DOCUMENTED_IN_PROSE"
        assert re.search(rf"\b{key}\b", text), f"{key} is no longer named in .env.example"
        assert key not in documented, f"{key} now has an entry line; drop it from DOCUMENTED_IN_PROSE"


def test_deprecated_aliases_follow_the_convention() -> None:
    from routers.env_compat import ALIASES
    documented = documented_keys(ENV_EXAMPLE)
    assert ALIASES
    assert not sorted(c for c in ALIASES if c not in documented), "every canonical name needs an entry"
    assert not sorted(o for o in ALIASES.values() if o in documented), "deprecated names never get an entry"


def test_every_documented_key_is_read() -> None:
    unread = unread_documented(REPO_ROOT, _repo_files(), DOCUMENTED_NOT_READ)
    assert not unread, (
        "keys documented in .env.example that nothing reads "
        "(remove them, or add a DOCUMENTED_NOT_READ entry with a reason):\n"
        + "\n".join(f"  {n}" for n in unread))


def test_documented_not_read_entries_are_still_needed() -> None:
    documented = documented_keys(ENV_EXAMPLE)
    unread = set(unread_documented(REPO_ROOT, _repo_files(), {}))
    stale = sorted(k for k in DOCUMENTED_NOT_READ if k not in documented or k not in unread)
    assert not stale, f"stale DOCUMENTED_NOT_READ entries (undocumented or now read): {stale}"
    assert all(reason.strip() for reason in DOCUMENTED_NOT_READ.values())
    assert all(reason.strip() for reason in EXEMPT.values())
