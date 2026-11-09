import pathlib
import textwrap

from test_env_surface import (
    collect_env_reads,
    collect_from_source,
    collect_from_sources,
    documented_keys,
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
        FIELDS = [{"env": "lowercase_name"}, {"env": 5}, {"env": NAME}, {"env": "Mixed Case"}]
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


def test_server_tree_skips_tests(tmp_path: pathlib.Path) -> None:
    (tmp_path / "routers").mkdir()
    (tmp_path / "tests").mkdir()
    (tmp_path / "routers" / "a.py").write_text('import os\nos.environ.get("TREE_KEY")\n')
    (tmp_path / "tests" / "test_a.py").write_text('import os\nos.environ.get("TEST_ONLY_KEY")\n')
    assert collect_env_reads(tmp_path) == {"TREE_KEY": "routers/a.py"}


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
    (satellite / "app.py").write_text('import os\nos.getenv("SATELLITE_PY_KEY")\n')
    (satellite / "run.sh").write_text('PORT="${SATELLITE_SH_KEY:-1}"\n')
    (satellite / "README.md").write_text("Set FAKE_KEY to anything.\n")
    sources = root / "apps" / "vera-mac" / "Sources"
    sources.mkdir(parents=True)
    (sources / "Config.swift").write_text('let base = env["APP_KEY"]\n')
    (root / "scripts").mkdir()
    (root / "scripts" / "sync.py").write_text('import os\nos.environ.get("SCRIPT_KEY")\n')
    (root / "docker-compose.yml").write_text("services:\n  api:\n    environment:\n      - COMPOSE_KEY=1\n")
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
    assert unread_documented(tmp_path, {}) == []


def test_documented_key_nothing_reads_fails(tmp_path: pathlib.Path) -> None:
    _fake_repo(tmp_path, "SERVER_KEY=\nFAKE_KEY=\n")
    assert unread_documented(tmp_path, {}) == ["FAKE_KEY"]
    assert unread_documented(tmp_path, {"FAKE_KEY": "seeded by a vein option"}) == []
