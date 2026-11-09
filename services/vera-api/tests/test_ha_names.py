import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "routers"))

import ha_names as hn
import home_reconcile_match as mm


def st(eid, friendly=None):
    a = {"friendly_name": friendly} if friendly is not None else {}
    return {"entity_id": eid, "attributes": a}


NAMES = hn.parse_names([
    ["switch.desk_lamp", "Desk Lamp", "Power Strip", "Study"],
    ["climate.thermostat", "", "Thermostat", "Hallway"],
    ["sensor.archive_archive_job_state", "Archive Job state", "Archive", None],
    ["device_tracker.server_2", "Server", "Server", None],
    ["light.den_light", "Den Light", "Den Fan", "Den"],
    ["sensor.no_device", "Outdoor Temp", None, None],
    "junk", [1, 2], ["too", "short"],
])


def test_parse_names_tolerates_junk():
    assert set(NAMES) == {"switch.desk_lamp", "climate.thermostat", "sensor.archive_archive_job_state",
                          "device_tracker.server_2", "light.den_light", "sensor.no_device"}
    assert NAMES["climate.thermostat"] == {"entity": "", "device": "Thermostat", "area": "Hallway"}
    assert NAMES["sensor.no_device"]["device"] == ""
    print("ok test_parse_names_tolerates_junk")


def test_compose():
    assert hn.compose("Desk Lamp", "Power Strip") == "Power Strip Desk Lamp"
    assert hn.compose("", "Thermostat") == "Thermostat"
    assert hn.compose("Outdoor Temp", None) == "Outdoor Temp"
    assert hn.compose("Server", "Server") == "Server"
    assert hn.compose("Den Purifier Fan", "Den Purifier") == "Den Purifier Fan"
    assert hn.compose("Purifier", "Pure") == "Pure Purifier"
    assert hn.compose(None, None) == ""
    print("ok test_compose")


def test_display_name_prefers_registry_then_friendly_then_id():
    assert hn.display_name(st("switch.desk_lamp", "Desk Lamp"), NAMES) == \
        "Power Strip Desk Lamp"
    assert hn.display_name(st("device_tracker.server_2", "Server Server"), NAMES) == "Server"
    assert hn.display_name(st("switch.desk_lamp", "Desk Lamp"), {}) == "Desk Lamp"
    assert hn.display_name(st("switch.desk_lamp", "Desk Lamp")) == "Desk Lamp"
    assert hn.display_name(st("light.kitchen_ceiling"), {}) == "Kitchen Ceiling"
    assert hn.display_name(st("light.kitchen_ceiling", ""), {}) == "Kitchen Ceiling"
    print("ok test_display_name_prefers_registry_then_friendly_then_id")


def test_candidates_keep_old_and_new_names():
    c = hn.name_candidates(st("switch.desk_lamp", "Desk Lamp"), NAMES)
    assert c[0] == "Power Strip Desk Lamp"
    for want in ("Desk Lamp", "Power Strip", "Study Power Strip Desk Lamp"):
        assert want in c, (want, c)
    assert len({x.lower() for x in c}) == len(c)
    c2 = hn.name_candidates(st("light.den_light", "Den Light"), NAMES)
    assert "Den Light" in c2 and "Den Fan Den Light" in c2
    assert not any(x.lower().startswith("den den") for x in c2), c2
    print("ok test_candidates_keep_old_and_new_names")


def test_match_name_contains_across_naming_schemes():
    states = [st("switch.desk_lamp", "Desk Lamp"), st("climate.thermostat", "Thermostat"),
              st("light.den_light", "Den Light")]

    def q(v, names=NAMES):
        return mm.match_entities(states, {"by": "name_contains", "value": v}, names)

    assert q("power strip desk") == ["switch.desk_lamp"]
    assert q("desk lamp") == ["switch.desk_lamp"]
    assert q("hallway") == ["climate.thermostat"]
    assert q("den fan den light") == ["light.den_light"]
    assert q("desk lamp", None) == ["switch.desk_lamp"]
    bare = [st("switch.desk_lamp")]
    assert mm.match_entities(bare, {"by": "name_contains", "value": "power strip"}, NAMES) == \
        ["switch.desk_lamp"]
    print("ok test_match_name_contains_across_naming_schemes")


if __name__ == "__main__":
    test_parse_names_tolerates_junk()
    test_compose()
    test_display_name_prefers_registry_then_friendly_then_id()
    test_candidates_keep_old_and_new_names()
    test_match_name_contains_across_naming_schemes()
    print("\nall ha_names tests passed")
