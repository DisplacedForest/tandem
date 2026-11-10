import ast
import pathlib
import textwrap

import pytest

from test_env_surface import (
    REPO_ROOT,
    _walk_scopes,
    collect_env_reads,
    collect_from_source,
    collect_from_sources,
    compose_reads,
    documented_keys,
    shell_reads,
    swift_reads,
    tracked_files,
    undocumented_reads,
    unread_documented,
)


def _keys(source: str) -> set[str]:
    return collect_from_source(textwrap.dedent(source))


def test_direct_reads() -> None:
    assert _keys("""
        import os
        a = os.environ.get("DIRECT_GET")
        b = os.getenv("DIRECT_GETENV")
        c = os.environ["DIRECT_SUBSCRIPT"]
        d = os.environ.get(key="DIRECT_KEYWORD")
    """) == {"DIRECT_GET", "DIRECT_GETENV", "DIRECT_SUBSCRIPT", "DIRECT_KEYWORD"}


def test_env_compat_module_import() -> None:
    assert _keys("""
        from routers import env_compat
        env_compat.read("COMPAT_MODULE")
        env_compat.is_set(name="COMPAT_MODULE_KEYWORD")
    """) == {"COMPAT_MODULE", "COMPAT_MODULE_KEYWORD"}


def test_env_compat_relative_module_alias() -> None:
    assert _keys("""
        from . import env_compat as ec
        ec.is_set("COMPAT_ALIAS")
    """) == {"COMPAT_ALIAS"}


def test_env_compat_function_imports() -> None:
    assert _keys("""
        from .env_compat import read as compat_read
        from routers.env_compat import is_set
        compat_read("COMPAT_READ_ALIAS", "fallback")
        is_set("COMPAT_IS_SET")
    """) == {"COMPAT_READ_ALIAS", "COMPAT_IS_SET"}


def test_env_compat_import_inside_function() -> None:
    assert _keys("""
        def lookup():
            from . import env_compat
            return env_compat.read("COMPAT_LOCAL_IMPORT")
    """) == {"COMPAT_LOCAL_IMPORT"}


def test_env_field_in_dict_literal() -> None:
    assert _keys("""
        FIELDS = [{"id": "url", "env": "FIELD_KEY", "label": "Base URL"}]
    """) == {"FIELD_KEY"}


def test_helper_positional_and_keyword_call_sites() -> None:
    assert _keys("""
        import os
        def _envf(name, default):
            return float(os.environ.get(name, default))
        A = _envf("HELPER_POSITIONAL", "1")
        B = _envf(default="2", name="HELPER_KEYWORD")
    """) == {"HELPER_POSITIONAL", "HELPER_KEYWORD"}


def test_helper_keyword_only_parameter() -> None:
    assert _keys("""
        import os
        def _flag(*, key: str) -> bool:
            return os.getenv(key, "") == "1"
        _flag(key="HELPER_KEYWORD_ONLY")
    """) == {"HELPER_KEYWORD_ONLY"}


def test_nested_helper() -> None:
    assert _keys("""
        import os
        def outer():
            def inner(key):
                return os.environ[key]
            return inner("NESTED_HELPER")
    """) == {"NESTED_HELPER"}


def test_helper_over_env_compat_and_chained_helper() -> None:
    assert _keys("""
        from . import env_compat
        def _value(name):
            return env_compat.read(name)
        def _number(name, default):
            return int(_value(name) or default)
        _number("CHAINED_HELPER", 3)
        _value("COMPAT_HELPER")
    """) == {"CHAINED_HELPER", "COMPAT_HELPER"}


def test_name_bound_to_literal_choices() -> None:
    assert _keys("""
        import os
        def _kwargs(name):
            return os.environ.get(name)
        def pick(mode):
            key = "CHOICE_ON" if mode == "on" else "CHOICE_OFF"
            return _kwargs(key)
    """) == {"CHOICE_ON", "CHOICE_OFF"}


def test_cross_module_helper_import() -> None:
    found = collect_from_sources({
        "routers/budget.py": textwrap.dedent("""
            import os
            def budget(name: str, default: int) -> int:
                return int(os.environ.get(name, "") or default)
        """),
        "routers/research.py": textwrap.dedent("""
            from .budget import budget as limit
            STEPS = limit("CROSS_MODULE_HELPER", 4)
        """),
    })
    assert found == {"CROSS_MODULE_HELPER": "routers/research.py"}


def test_dynamic_names_are_not_collected() -> None:
    assert _keys("""
        import os
        def lookup(job, prefix):
            a = os.environ.get(f"SCHEDULE_{job.upper()}")
            b = os.getenv("PREFIX_" + prefix)
            c = os.environ["BASE_" + job]
            return a, b, c
    """) == set()


def test_env_field_needs_an_uppercase_string() -> None:
    assert _keys("""
        NAME = "FIELD_FROM_NAME"
        FIELDS = [
            {"id": "a", "label": "A", "env": "lowercase_name"},
            {"id": "b", "label": "B", "env": 5},
            {"id": "c", "label": "C", "env": NAME},
            {"id": "d", "label": "D", "env": "Mixed Case"},
        ]
    """) == set()


def test_helper_with_non_literal_argument_is_not_collected() -> None:
    assert _keys("""
        import os
        def _envf(name, default):
            return float(os.environ.get(name, default))
        def compute():
            return "COMPUTED"
        A = _envf(compute(), "1")
        B = _envf("PRE_" + compute(), "1")
        C = _envf(f"{compute()}_X", "1")
    """) == set()


def test_unrelated_read_functions_are_not_collected() -> None:
    assert _keys("""
        from . import config_file
        from .storage import read
        config_file.read("OTHER_MODULE_READ")
        read("PLAIN_READ")
        handle = open("x")
        handle.read("FILE_READ")
        settings.is_set("OTHER_IS_SET")
    """) == set()


def test_env_field_needs_the_field_shape() -> None:
    assert _keys("""
        metadata = {"env": "PRODUCTION"}
        partial = {"id": "x", "env": "MISSING_LABEL"}
        option = {"id": "taste", "label": "Taste", "type": "text", "env": "OPTION_SEED"}
    """) == {"OPTION_SEED"}


def test_parameter_shadows_helper() -> None:
    assert _keys("""
        import os
        def read(key):
            return os.getenv(key)
        def f(read):
            return read("NOT_AN_ENV_KEY")
        read("REAL_HELPER_KEY")
    """) == {"REAL_HELPER_KEY"}


def test_local_reassignment_shadows_helper() -> None:
    assert _keys("""
        import os
        def _env(key):
            return os.getenv(key)
        def f(lookup):
            _env = lookup
            return _env("REASSIGNED_KEY")
        def g():
            def _env(value):
                return value
            return _env("NESTED_NON_HELPER_KEY")
    """) == set()


def test_shadowed_compat_import() -> None:
    assert _keys("""
        from .env_compat import read
        from . import env_compat
        def f(read, env_compat):
            return read("PARAM_SHADOWED_KEY"), env_compat.read("MODULE_SHADOWED_KEY")
        def g(store):
            read = store.read
            return read("LOCAL_SHADOWED_KEY")
        read("COMPAT_KEY")
    """) == {"COMPAT_KEY"}


def test_annotations_are_scanned() -> None:
    assert _keys("""
        import os
        def f(x: os.getenv("ANNOTATION_KEY"), *, y: os.environ["KWONLY_ANNOTATION_KEY"] = None) \\
                -> os.environ.get("RETURN_ANNOTATION_KEY"):
            pass
    """) == {"ANNOTATION_KEY", "KWONLY_ANNOTATION_KEY", "RETURN_ANNOTATION_KEY"}


def test_more_direct_read_forms() -> None:
    assert _keys("""
        import os
        os.environ.setdefault("SETDEFAULT_KEY", "1")
        present = "MEMBERSHIP_KEY" in os.environ
        absent = "NOT_IN_KEY" not in os.environ
        os.environ.pop("POP_KEY", None)
    """) == {"SETDEFAULT_KEY", "MEMBERSHIP_KEY", "NOT_IN_KEY", "POP_KEY"}


def test_every_node_belongs_to_one_scope() -> None:
    tree = ast.parse(textwrap.dedent("""
        import os
        @decorate(os.getenv("DECORATOR_KEY"))
        class C(Base, metaclass=os.environ["META_KEY"]):
            def m(self, a: int = os.getenv("DEFAULT_KEY"), *rest: str, **kw: str) -> str:
                f = lambda z=os.getenv("LAMBDA_DEFAULT_KEY"): z
                return [x for x in f()]
    """))
    seen: list[int] = []
    for own, _ in _walk_scopes(tree):
        seen.extend(id(node) for node in own)
    every = [id(node) for node in ast.walk(tree) if node is not tree]
    assert sorted(seen) == sorted(every)
    assert collect_from_sources({"m.py": ast.unparse(tree)}).keys() == {
        "DECORATOR_KEY", "META_KEY", "DEFAULT_KEY", "LAMBDA_DEFAULT_KEY"}


def test_comment_and_docstring_mentions_are_not_reads() -> None:
    assert _keys('''
        import os
        def f():
            """Reads DOCSTRING_KEY from the environment."""
            return 1
        # os.environ.get("COMMENT_KEY")
    ''') == set()


def test_swift_reads() -> None:
    source = textwrap.dedent("""
        let a = ProcessInfo.processInfo.environment["PROCESS_KEY"]
        let env = ProcessInfo.processInfo.environment
        let b = env["LOCAL_ENV_KEY"]?.nilIfBlank
        func resolve(environment: [String: String]) -> String? { environment["PARAM_ENV_KEY"] }
        func value(_ envKey: String, _ fileKey: String) -> String? {
            if let raw = env[envKey] { return raw }
            return nil
        }
        let c = value("HELPER_KEY", "file_key")
        // let d = env["LINE_COMMENT_KEY"]
        /* let e = env["BLOCK_COMMENT_KEY"] */
        let url = "https://example.invalid/path" ; let f = env["AFTER_URL_KEY"]
        let names = ["model_base": "MAPPING_ONLY_KEY"]
        let other = settings["SETTINGS_KEY"]
    """)
    assert swift_reads(source) == {"PROCESS_KEY", "LOCAL_ENV_KEY", "PARAM_ENV_KEY", "HELPER_KEY", "AFTER_URL_KEY"}


def test_shell_reads() -> None:
    source = textwrap.dedent("""
        #!/bin/bash
        # export COMMENT_KEY=1 and $COMMENT_EXPANSION_KEY
        HOST="${HOST_KEY:-0.0.0.0}"
        echo "$PLAIN_KEY"
        export EXPORTED_KEY="${EXPORTED_KEY:-x}"
        : "${ASSIGN_DEFAULT_KEY:=3}"
        ASSIGNED_ONLY_KEY=3
    """)
    assert shell_reads(source) == {"HOST_KEY", "PLAIN_KEY", "EXPORTED_KEY", "ASSIGN_DEFAULT_KEY"}


def test_compose_reads() -> None:
    source = textwrap.dedent("""
        # COMMENT_KEY=1 ${COMMENT_EXPANSION_KEY}
        services:
          api:
            image: "example/${IMAGE_TAG_KEY:-latest}"
            environment:
              - LIST_KEY=1
              MAP_KEY: "2"
              - BARE_KEY
            ports:
              - "8080:8080"
            labels:
              NOT_ENV_KEY: "x"
    """)
    assert compose_reads(source) == {"IMAGE_TAG_KEY", "LIST_KEY", "MAP_KEY", "BARE_KEY"}


def _walk(root: pathlib.Path) -> list[str]:
    return sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())


def test_server_tree_skips_tests(tmp_path: pathlib.Path) -> None:
    (tmp_path / "routers").mkdir()
    (tmp_path / "tests").mkdir()
    (tmp_path / "routers" / "a.py").write_text('import os\nos.environ.get("TREE_KEY")\n')
    (tmp_path / "routers" / "b.py").write_text('import os\nos.environ.get("UNLISTED_KEY")\n')
    (tmp_path / "tests" / "test_a.py").write_text('import os\nos.environ.get("TEST_ONLY_KEY")\n')
    assert collect_env_reads(tmp_path, ["routers/a.py", "tests/test_a.py"]) == {"TREE_KEY": "routers/a.py"}


def test_undocumented_read_is_reported(tmp_path: pathlib.Path) -> None:
    env = tmp_path / ".env.example"
    env.write_text("# a comment\nKNOWN_KEY=\n#TUNED_KEY=3\n")
    documented = documented_keys(env)
    assert documented == {"KNOWN_KEY", "TUNED_KEY"}
    reads = {"KNOWN_KEY": "a.py", "TUNED_KEY": "a.py", "NEW_KEY": "b.py", "BUILD_KEY": "c.py"}
    assert undocumented_reads(reads, documented, {"BUILD_KEY": "build only"}) == {"NEW_KEY": "b.py"}


def _fake_repo(root: pathlib.Path, env_example: str) -> None:
    api = root / "services" / "vera-api"
    (api / "routers").mkdir(parents=True)
    (api / "routers" / "a.py").write_text('import os\nos.environ.get("SERVER_KEY")\n')
    (api / "data_paths.py").write_text('STORE_PATHS = {"STORE_KEY": "store.db"}\n')
    satellite = root / "services" / "satellite"
    satellite.mkdir()
    (satellite / "app.py").write_text(
        'import os\n\n\ndef main():\n    """Mentions DOCSTRING_ONLY_KEY."""\n'
        '    return os.getenv("SATELLITE_PY_KEY")\n# os.getenv("PY_COMMENT_ONLY_KEY")\n')
    (satellite / "run.sh").write_text('#!/bin/sh\n# ${SH_COMMENT_ONLY_KEY}\nPORT="${SATELLITE_SH_KEY:-1}"\n')
    (satellite / "README.md").write_text("Set FAKE_KEY to anything.\n")
    (satellite / "service.plist.template").write_text("<string>PLIST_ONLY_KEY</string>\n")
    sources = root / "apps" / "vera-mac" / "Sources" / "Vera"
    sources.mkdir(parents=True)
    (sources / "Config.swift").write_text(
        'let env = ProcessInfo.processInfo.environment\nlet base = env["APP_KEY"]\n'
        '// env["SWIFT_COMMENT_ONLY_KEY"]\n')
    (sources / "ConfigSelftest.swift").write_text('let base = env["SELFTEST_ONLY_KEY"]\n')
    (sources / "ConfigFixture.swift").write_text('let base = env["FIXTURE_ONLY_KEY"]\n')
    (root / "scripts" / "tests").mkdir(parents=True)
    (root / "scripts" / "sync.py").write_text('import os\nos.environ.get("SCRIPT_KEY")\n')
    (root / "scripts" / "tests" / "test_sync.py").write_text('import os\nos.environ.get("SCRIPT_TEST_ONLY_KEY")\n')
    (root / "docker-compose.yml").write_text(
        "# ${COMPOSE_COMMENT_ONLY_KEY}\nservices:\n  api:\n    environment:\n      - COMPOSE_KEY=1\n")
    (root / ".env.example").write_text(env_example)


def test_every_documented_key_needs_a_reader(tmp_path: pathlib.Path) -> None:
    _fake_repo(tmp_path, textwrap.dedent("""
        SERVER_KEY=
        #STORE_KEY=/data/store.db
        SATELLITE_PY_KEY=
        #SATELLITE_SH_KEY=1
        APP_KEY=
        SCRIPT_KEY=
        COMPOSE_KEY=
        #SCHEDULE_NIGHTLY=0 3 * * *
        #SCHEDULE_NIGHTLY_ENABLED=true
    """))
    assert unread_documented(tmp_path, _walk(tmp_path), {}) == []


def test_documented_key_nothing_reads_fails(tmp_path: pathlib.Path) -> None:
    _fake_repo(tmp_path, "SERVER_KEY=\nFAKE_KEY=\n")
    assert unread_documented(tmp_path, _walk(tmp_path), {}) == ["FAKE_KEY"]
    assert unread_documented(tmp_path, _walk(tmp_path), {"FAKE_KEY": "seeded by a vein option"}) == []


def test_mentions_outside_readers_do_not_count(tmp_path: pathlib.Path) -> None:
    mentioned = ["DOCSTRING_ONLY_KEY", "PY_COMMENT_ONLY_KEY", "SH_COMMENT_ONLY_KEY", "PLIST_ONLY_KEY",
                 "SWIFT_COMMENT_ONLY_KEY", "SELFTEST_ONLY_KEY", "FIXTURE_ONLY_KEY", "SCRIPT_TEST_ONLY_KEY",
                 "COMPOSE_COMMENT_ONLY_KEY"]
    _fake_repo(tmp_path, "".join(f"{k}=\n" for k in mentioned))
    assert unread_documented(tmp_path, _walk(tmp_path), {}) == sorted(mentioned)


def test_removing_production_readers_reports_the_key(tmp_path: pathlib.Path) -> None:
    _fake_repo(tmp_path, "APP_KEY=\n")
    assert unread_documented(tmp_path, _walk(tmp_path), {}) == []
    (tmp_path / "apps" / "vera-mac" / "Sources" / "Vera" / "ConfigSelftest.swift").write_text(
        'let base = env["APP_KEY"]\n')
    (tmp_path / "apps" / "vera-mac" / "Sources" / "Vera" / "Config.swift").write_text("let base = \"\"\n")
    assert unread_documented(tmp_path, _walk(tmp_path), {}) == ["APP_KEY"]


def test_untracked_files_are_ignored(tmp_path: pathlib.Path) -> None:
    _fake_repo(tmp_path, "SCRIPT_KEY=\n")
    files = [f for f in _walk(tmp_path) if f != "scripts/sync.py"]
    assert unread_documented(tmp_path, files, {}) == ["SCRIPT_KEY"]


def test_tracked_files_lists_only_tracked_files(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GIT_DIR", "/nonexistent/git-dir")
    monkeypatch.setenv("GIT_WORK_TREE", "/nonexistent/work-tree")
    files = tracked_files(REPO_ROOT)
    assert "services/vera-api/main.py" in files
    assert "scripts/leak-gate.sh" not in files
    assert not any("__pycache__" in f for f in files)


def test_tracked_files_fails_outside_a_work_tree(tmp_path: pathlib.Path) -> None:
    with pytest.raises(AssertionError, match="git work tree"):
        tracked_files(tmp_path)
