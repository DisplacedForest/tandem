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
