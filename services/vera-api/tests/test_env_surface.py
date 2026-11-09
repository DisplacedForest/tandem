"""Config-surface completeness guard — every env var vera-api reads must be discoverable
in the repo-root .env.example (active `NAME=` or documented `#NAME=` line), or carry an
explicit exemption here with a reason. Fails the moment a new os.environ/os.getenv read
lands without documentation, so the surface can never silently drift again.
Run: python3 -m pytest tests/test_env_surface.py
"""
import ast
import pathlib
import re
from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass, field

API_ROOT = pathlib.Path(__file__).resolve().parent.parent          # services/vera-api
ENV_EXAMPLE = API_ROOT.parent.parent / ".env.example"              # repo root
REPO_ROOT = API_ROOT.parent.parent

# Vars deliberately NOT in .env.example — every entry needs a reason.
EXEMPT: dict[str, str] = {
    "VERA_VERSION": "image-build fallback for /version when no VERSION file is baked; not deployment config",
}

DOCUMENTED_NOT_READ: dict[str, str] = {
    "MEDIA_CURATION_TASTE": "seeded by a media vein's taste option when its definition declares this key as its env seed",
}

DYNAMIC_KEY_PATTERNS: dict[str, str] = {
    r"SCHEDULE_[A-Z0-9_]+": "the scheduler builds SCHEDULE_<JOB> and SCHEDULE_<JOB>_ENABLED from each job id",
}

ENV_KEY = re.compile(r"^[A-Z][A-Z0-9_]+$")
WORD_SEARCH_SKIP_SUFFIXES = frozenset({".md", ".txt"})
_COMPAT_FUNCS = ("read", "is_set")
_SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)
_FUNCS = (ast.FunctionDef, ast.AsyncFunctionDef)

Spec = tuple[int | None, str]
Helpers = dict[str, set[Spec]]


@dataclass
class _Frame:
    scope: ast.AST
    params: set[str]
    assigned: dict[str, list[ast.expr | None]] = field(default_factory=dict)


def _params(scope: ast.AST) -> set[str]:
    if not isinstance(scope, (*_FUNCS, ast.Lambda)):
        return set()
    a = scope.args
    names = [x.arg for x in a.posonlyargs + a.args + a.kwonlyargs]
    names += [x.arg for x in (a.vararg, a.kwarg) if x is not None]
    return set(names)


def _outer_parts(node: ast.AST) -> list[ast.AST]:
    parts: list[ast.AST] = list(getattr(node, "decorator_list", []))
    if isinstance(node, ast.ClassDef):
        parts += node.bases + [k.value for k in node.keywords]
    elif isinstance(node, (*_FUNCS, ast.Lambda)):
        parts += node.args.defaults + [d for d in node.args.kw_defaults if d is not None]
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
            frame.assigned.setdefault(node.name, []).append(None)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                frame.assigned.setdefault((alias.asname or alias.name).split(".")[0], []).append(None)
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


def _literals(node: ast.expr | None, chain: list[_Frame]) -> set[str]:
    if isinstance(node, ast.Constant):
        return {node.value} if isinstance(node.value, str) else set()
    if isinstance(node, ast.IfExp):
        body, orelse = _literals(node.body, chain), _literals(node.orelse, chain)
        return body | orelse if body and orelse else set()
    if isinstance(node, ast.Name) and chain:
        frame = _binding(node.id, chain)
        if frame is None or node.id in frame.params:
            return set()
        parts = [_literals(value, []) for value in frame.assigned[node.id]]
        return set().union(*parts) if parts and all(parts) else set()
    return set()


def _compat_bindings(tree: ast.Module) -> tuple[set[str], dict[str, str]]:
    modules: set[str] = set()
    funcs: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(a.asname for a in node.names
                           if a.asname and a.name.split(".")[-1] == "env_compat")
        elif isinstance(node, ast.ImportFrom):
            from_compat = (node.module or "").split(".")[-1] == "env_compat"
            for alias in node.names:
                if alias.name == "env_compat":
                    modules.add(alias.asname or alias.name)
                elif from_compat and alias.name in _COMPAT_FUNCS:
                    funcs[alias.asname or alias.name] = alias.name
    return modules, funcs


def _arg(call: ast.Call, index: int | None, keyword: str) -> ast.expr | None:
    if index is not None and len(call.args) > index \
            and not any(isinstance(a, ast.Starred) for a in call.args[:index + 1]):
        return call.args[index]
    return next((k.value for k in call.keywords if k.arg == keyword), None)


def _key_args(node: ast.AST, modules: set[str], funcs: dict[str, str], helpers: Helpers) -> list[ast.expr]:
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) \
            and "environ" in ast.unparse(node.value):
        return [node.slice]
    if not isinstance(node, ast.Call):
        return []
    func = node.func
    keyword = None
    if isinstance(func, ast.Attribute):
        src = ast.unparse(func)
        if src.endswith("environ.get") or src.endswith("os.getenv"):
            keyword = "key"
        elif func.attr in _COMPAT_FUNCS and (
                (isinstance(func.value, ast.Name) and func.value.id in modules)
                or ast.unparse(func.value).split(".")[-1] == "env_compat"):
            keyword = "name"
    elif isinstance(func, ast.Name):
        if func.id in funcs:
            keyword = "name"
        elif func.id in helpers:
            found = (_arg(node, index, param) for index, param in sorted(helpers[func.id], key=str))
            return [a for a in found if a is not None]
    if keyword is None:
        return []
    found_arg = _arg(node, 0, keyword)
    return [found_arg] if found_arg is not None else []


def _env_dict_keys(node: ast.Dict) -> set[str]:
    return {v.value for k, v in zip(node.keys, node.values)
            if isinstance(k, ast.Constant) and k.value == "env"
            and isinstance(v, ast.Constant) and isinstance(v.value, str) and ENV_KEY.match(v.value)}


def _spec(func: ast.FunctionDef | ast.AsyncFunctionDef, param: str) -> Spec:
    positional = [a.arg for a in func.args.posonlyargs + func.args.args]
    return (positional.index(param) if param in positional else None, param)


def _scan(tree: ast.Module, helpers: Helpers) -> tuple[set[str], Helpers]:
    modules, funcs = _compat_bindings(tree)
    keys: set[str] = set()
    found: Helpers = {}
    for own, chain in _walk_scopes(tree):
        for node in own:
            if isinstance(node, ast.Dict):
                keys |= _env_dict_keys(node)
            for arg in _key_args(node, modules, funcs, helpers):
                if isinstance(arg, ast.Name):
                    frame = _binding(arg.id, chain)
                    if frame is not None and arg.id in frame.params:
                        if isinstance(frame.scope, _FUNCS):
                            found.setdefault(frame.scope.name, set()).add(_spec(frame.scope, arg.id))
                        continue
                keys |= _literals(arg, chain)
    return keys, found


def _analyze(tree: ast.Module, imported: Helpers) -> tuple[set[str], Helpers]:
    helpers: Helpers = {name: set(specs) for name, specs in imported.items()}
    while True:
        keys, found = _scan(tree, helpers)
        grown = False
        for name, specs in found.items():
            if not specs <= helpers.get(name, set()):
                helpers.setdefault(name, set()).update(specs)
                grown = True
        if not grown:
            return keys, found


def _import_target(rel: str, node: ast.ImportFrom) -> str:
    module_path = (node.module or "").replace(".", "/") + ".py"
    if not node.level:
        return pathlib.PurePosixPath(module_path).as_posix()
    base = pathlib.PurePosixPath(rel).parent
    for _ in range(node.level - 1):
        base = base.parent
    return (base / module_path).as_posix()


def _imported_helpers(rel: str, tree: ast.Module, exported: Mapping[str, Helpers]) -> Helpers:
    out: Helpers = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            source = exported.get(_import_target(rel, node), {})
            for alias in node.names:
                if alias.name in source:
                    out.setdefault(alias.asname or alias.name, set()).update(source[alias.name])
    return out


def collect_from_sources(sources: Mapping[str, str]) -> dict[str, str]:
    trees: dict[str, ast.Module] = {}
    for rel, source in sources.items():
        try:
            trees[rel] = ast.parse(source)
        except SyntaxError:
            continue
    local = {rel: _analyze(tree, {}) for rel, tree in trees.items()}
    exported = {rel: helpers for rel, (_, helpers) in local.items()}
    out: dict[str, str] = {}
    for rel in sorted(trees):
        keys = local[rel][0]
        imported = _imported_helpers(rel, trees[rel], exported)
        if imported:
            keys = _analyze(trees[rel], imported)[0]
        for key in sorted(keys):
            out.setdefault(key, rel)
    return out


def collect_from_source(source: str) -> set[str]:
    return set(collect_from_sources({"module.py": source}))


def _python_sources(root: pathlib.Path) -> dict[str, str]:
    return {p.relative_to(root).as_posix(): p.read_text(errors="ignore")
            for p in sorted(root.rglob("*.py"))
            if not {"tests", "__pycache__"} & set(p.relative_to(root).parts)}


def collect_env_reads(root: pathlib.Path) -> dict[str, str]:
    return collect_from_sources(_python_sources(root))


def documented_keys(env_example: pathlib.Path) -> set[str]:
    return set(re.findall(r"^\s*#?([A-Z][A-Z0-9_]+)=", env_example.read_text(), re.M))


def undocumented_reads(reads: Mapping[str, str], documented: set[str],
                       exempt: Mapping[str, str]) -> dict[str, str]:
    return {name: where for name, where in sorted(reads.items())
            if name not in documented and name not in exempt}


def _files(root: pathlib.Path) -> Iterator[pathlib.Path]:
    if root.is_file():
        yield root
        return
    if not root.is_dir():
        return
    for p in sorted(root.rglob("*")):
        if p.is_file() and "__pycache__" not in p.parts and p.suffix not in WORD_SEARCH_SKIP_SUFFIXES:
            yield p


def _words(paths: Iterable[pathlib.Path]) -> set[str]:
    words: set[str] = set()
    for p in paths:
        words.update(re.findall(r"\w+", p.read_text(errors="ignore")))
    return words


def store_path_keys(repo_root: pathlib.Path) -> set[str]:
    table = repo_root / "services" / "vera-api" / "data_paths.py"
    if not table.is_file():
        return set()
    for node in ast.parse(table.read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "STORE_PATHS"
                                                for t in node.targets) and isinstance(node.value, ast.Dict):
            return {k.value for k in node.value.keys if isinstance(k, ast.Constant) and isinstance(k.value, str)}
    return set()


def reads_outside_server(repo_root: pathlib.Path) -> set[str]:
    found: set[str] = set()
    services = repo_root / "services"
    satellites = sorted(p for p in services.iterdir() if p.is_dir() and p.name != "vera-api") \
        if services.is_dir() else []
    for satellite in satellites:
        found |= set(collect_env_reads(satellite))
        found |= _words(p for p in _files(satellite) if p.suffix != ".py")
    found |= _words(_files(repo_root / "docker-compose.yml"))
    for place in ("apps/vera-mac/Sources", "apps/vera-mac/scripts", "scripts"):
        found |= _words(_files(repo_root / place))
    return found


def unread_documented(repo_root: pathlib.Path, allow: Mapping[str, str]) -> list[str]:
    documented = documented_keys(repo_root / ".env.example")
    read = set(collect_env_reads(repo_root / "services" / "vera-api"))
    read |= reads_outside_server(repo_root) | store_path_keys(repo_root)
    return sorted(key for key in documented
                  if key not in read and key not in allow
                  and not any(re.fullmatch(p, key) for p in DYNAMIC_KEY_PATTERNS))


def test_every_env_read_is_documented():
    reads = collect_env_reads(API_ROOT)
    assert reads, "extractor found no env reads — it is broken, not the codebase"
    undocumented = undocumented_reads(reads, documented_keys(ENV_EXAMPLE), EXEMPT)
    assert not undocumented, (
        "env vars read in code but missing from .env.example "
        "(add them there, or add an EXEMPT entry with a reason):\n"
        + "\n".join(f"  {n}  (first read in {w})" for n, w in undocumented.items()))


def test_exemptions_are_still_real():
    """An EXEMPT entry for a var nobody reads anymore is stale — prune it."""
    reads = collect_env_reads(API_ROOT)
    stale = set(EXEMPT) - set(reads)
    assert not stale, f"stale exemptions (no longer read anywhere): {sorted(stale)}"


def test_every_documented_key_is_read() -> None:
    unread = unread_documented(REPO_ROOT, DOCUMENTED_NOT_READ)
    assert not unread, (
        "keys documented in .env.example that nothing reads "
        "(remove them, or add a DOCUMENTED_NOT_READ entry with a reason):\n"
        + "\n".join(f"  {n}" for n in unread))


def test_documented_not_read_entries_are_still_needed() -> None:
    documented = documented_keys(ENV_EXAMPLE)
    unread = set(unread_documented(REPO_ROOT, {}))
    stale = sorted(k for k in DOCUMENTED_NOT_READ if k not in documented or k not in unread)
    assert not stale, f"stale DOCUMENTED_NOT_READ entries (undocumented or now read): {stale}"
    assert all(reason.strip() for reason in DOCUMENTED_NOT_READ.values())
    assert all(reason.strip() for reason in EXEMPT.values())
