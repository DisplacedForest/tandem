import main


def route_paths() -> set[str]:
    return set(main.app.openapi()['paths'])


def test_callerless_capabilities_are_not_registered() -> None:
    for name in ('knowledge', 'user_profile', 'reminders'):
        assert name not in main.CAPABILITIES


def test_knowledge_restore_and_reject_stay_mounted() -> None:
    paths = route_paths()
    assert '/knowledge/restore' in paths
    assert '/knowledge/reject' in paths


def test_callerless_routes_are_not_mounted() -> None:
    paths = route_paths()
    assert '/knowledge/query' not in paths
    assert not any(p.startswith('/profile/') or p.startswith('/reminders') for p in paths)


def test_uncalled_capabilities_are_not_registered() -> None:
    for name in ('search', 'images', 'knowledge_groom'):
        assert name not in main.CAPABILITIES


def test_uncalled_routes_are_not_mounted() -> None:
    paths = route_paths()
    for path in ('/search', '/images/search', '/knowledge/groom_pass'):
        assert path not in paths


def test_in_process_functions_remain_importable() -> None:
    import inspect

    from routers.pulse import _vera
    from routers.websearch import SearchRequest, search

    assert inspect.iscoroutinefunction(search)
    assert SearchRequest
    assert _vera


def test_modules_expose_no_router() -> None:
    from routers import images, knowledge_groom, websearch

    for module in (images, websearch, knowledge_groom):
        assert not hasattr(module, 'router')


def test_block_only_modules_are_not_mounted() -> None:
    from routers import updates, weather

    for name in ('weather', 'updates'):
        assert name not in main.CAPABILITIES
    for module in (weather, updates):
        assert not hasattr(module, 'router')
