"""Action spec unit tests. Standalone — run: python3 tests/test_actions_spec.py"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from routers import action_registry  # noqa: E402
from routers import action_spec as sp  # noqa: E402
from routers import home as ha
from routers import knowledge_actions, updates


def test_ha_allowlist():
    assert ha.ha_allowed("climate", "set_temperature")
    assert ha.ha_allowed("light", "turn_on")
    assert ha.ha_allowed("switch", "toggle")
    assert not ha.ha_allowed("lock", "unlock")          # safety: no lock control
    assert not ha.ha_allowed("climate", "set_fan_mode")  # only the allowlisted climate service


def test_media_player_allowed():
    # the whole media_player domain is in the default allowlist — playback control is benign
    for service in ("media_play", "media_pause", "media_next_track", "media_previous_track",
                    "volume_set", "select_source", "play_media"):
        assert ha.ha_allowed("media_player", service)
    assert sp.SPEC["ha.service"]["validate"](
        {"domain": "media_player", "service": "media_pause",
         "data": {"entity_id": "media_player.living_room"}}) is None


def test_ha_validate():
    assert sp.SPEC["ha.service"]["validate"](
        {"domain": "climate", "service": "set_temperature", "data": {"entity_id": "climate.x", "temperature": 70}}
    ) is None
    assert sp.SPEC["ha.service"]["validate"]({"domain": "lock", "service": "unlock"})  # error string (truthy)
    assert sp.SPEC["ha.service"]["validate"]({})  # missing domain/service


def test_knowledge_validate():
    assert sp.SPEC["knowledge.set"]["validate"]({"type": "appliance", "name": "x"}) is None
    assert sp.SPEC["knowledge.set"]["validate"]({"type": "appliance"})  # missing name
    assert sp.SPEC["knowledge.delete"]["validate"]({"entity_id": "appliance:x"}) is None
    assert sp.SPEC["knowledge.delete"]["validate"]({})  # missing identifier


def test_update_install_allowed():
    # Applying an HA update.* entity is the HA-domain apply path for stack updates.
    assert ha.ha_allowed("update", "install")
    assert sp.SPEC["ha.service"]["validate"](
        {"domain": "update", "service": "install", "data": {"entity_id": "update.bubble_card_update"}}) is None


def test_docker_update_spec():
    # Container apply via the host's container-management API; name or image identifies the target.
    assert sp.SPEC["docker.update"]["validate"]({"name": "radarr"}) is None
    assert sp.SPEC["docker.update"]["validate"]({"image": "x/radarr:latest"}) is None
    assert sp.SPEC["docker.update"]["validate"]({})  # needs name or image
    assert sp.SPEC["docker.update"]["risk"] == "high"
    assert sp.SPEC["docker.update"]["reversible"] is False
    assert "radarr" in sp.SPEC["docker.update"]["preview"]({"name": "radarr", "image": "x/radarr:latest"})


async def _sample_executor(args):
    return {"ok": True}


def test_autonomous_enrollment():
    assert [v for v, s in sp.SPEC.items() if s["autonomous"]] == []
    action_registry.register_action(
        "sample.import_link", validate=lambda a: None, preview=lambda a: "import",
        risk="low", reversible=True, autonomous=True, order=2_000_010, executor=_sample_executor)
    action_registry.register_action(
        "sample.adjust_count", validate=lambda a: None, preview=lambda a: "adjust",
        risk="low", reversible=True, autonomous=False, order=2_000_020, executor=_sample_executor)
    try:
        assert sp.is_autonomous("sample.import_link")
        assert [v for v, s in sp.SPEC.items() if s["autonomous"]] == ["sample.import_link"]
        assert not sp.is_autonomous("sample.adjust_count")
        assert not sp.is_autonomous("ha.service")
        assert not sp.is_autonomous("knowledge.set")
        assert not sp.is_autonomous("nonexistent.verb")
    finally:
        action_registry.unregister_action("sample.import_link")
        action_registry.unregister_action("sample.adjust_count")
    assert [v for v, s in sp.SPEC.items() if s["autonomous"]] == []


def test_autonomy_invariant():
    # autonomous requires risk in {none,low} AND reversible — anything else fails at load
    sp.check_autonomy_invariant(sp.SPEC)  # the live registry must pass
    bad_risk = {"x": {"risk": "medium", "reversible": True, "autonomous": True}}
    bad_rev = {"x": {"risk": "low", "reversible": False, "autonomous": True}}
    for bad in (bad_risk, bad_rev):
        try:
            sp.check_autonomy_invariant(bad)
            assert False, "invariant should have raised"
        except AssertionError as e:
            assert "cannot be autonomous" in str(e)
    # a dangerous verb left gated is fine
    sp.check_autonomy_invariant({"x": {"risk": "high", "reversible": False, "autonomous": False}})


def test_preview_strings():
    assert "climate.set_temperature" in sp.SPEC["ha.service"]["preview"](
        {"domain": "climate", "service": "set_temperature", "data": {"entity_id": "climate.x"}})
    assert "Record" in sp.SPEC["knowledge.set"]["preview"]({"type": "appliance", "name": "Heater", "attrs": {"a": 1}})
    assert sp.SPEC["health.check"]["risk"] == "none"


if __name__ == "__main__":
    test_ha_allowlist()
    test_media_player_allowed()
    test_ha_validate()
    test_knowledge_validate()
    test_update_install_allowed()
    test_docker_update_spec()
    test_autonomous_enrollment()
    test_autonomy_invariant()
    test_preview_strings()
    print("OK")
