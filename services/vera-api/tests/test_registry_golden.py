import asyncio
import os
import tempfile
from typing import Any

import pytest

import main
from routers import action_spec, actions, integrations, scheduler, vein_engine


def _load_built_in_blocks() -> None:
    saved = vein_engine.BLOCKS_DIR
    vein_engine.BLOCKS_DIR = os.path.join(tempfile.mkdtemp(), "missing-blocks")
    try:
        vein_engine.load_block_modules()
    finally:
        vein_engine.BLOCKS_DIR = saved


_load_built_in_blocks()

VERBS = [
    "authoring.skill_upsert", "ha.service", "knowledge.set", "knowledge.delete",
    "knowledge.reverify", "knowledge.promote", "kitchen.grocy_adjust", "kitchen.mealie_import",
    "health.check", "overseerr_request", "docker.update",
]

JOBS = [
    "pulse", "home_model", "home_reconcile", "home_digest", "conversation_extract",
    "weight_fit", "knowledge_groom",
]

REGISTRY_RESPONSE: dict[str, Any] = {
    "verbs": [
        {"verb": "authoring.skill_upsert", "risk": "high", "reversible": True, "autonomous": False,
         "summary": "create or modify a skill (Vera's own cognition config)",
         "args": '{"name": "...", "content": "...", "id": "...", "description": "..."}'},
        {"verb": "ha.service", "risk": "medium", "reversible": True, "autonomous": False,
         "summary": "call a Home Assistant service (the server enforces a configurable allowlist)",
         "args": '{"domain": "...", "service": "...", "data": {"entity_id": "...", ...}}'},
        {"verb": "knowledge.set", "risk": "low", "reversible": True, "autonomous": False,
         "summary": "record or update a durable home fact",
         "args": '{"type": "...", "name": "...", "attrs": {...}}'},
        {"verb": "knowledge.delete", "risk": "medium", "reversible": False, "autonomous": False,
         "summary": "remove a durable home fact",
         "args": '{"entity_id": "..."} or {"type": "...", "name": "..."}'},
        {"verb": "knowledge.reverify", "risk": "none", "reversible": True, "autonomous": False,
         "summary": "re-stamp a fact's last_verified to now",
         "args": '{"entity_id": "..."}'},
        {"verb": "knowledge.promote", "risk": "low", "reversible": True, "autonomous": False,
         "summary": "codify a knowledge type's schema",
         "args": '{"type": "...", "schema": {...}}'},
        {"verb": "kitchen.grocy_adjust", "risk": "low", "reversible": True, "autonomous": False,
         "summary": "adjust kitchen stock (op is add or consume)",
         "args": '{"product_id": N, "op": "add|consume", "amount": N}'},
        {"verb": "kitchen.mealie_import", "risk": "low", "reversible": True, "autonomous": True,
         "summary": "import a recipe by URL",
         "args": '{"url": "..."}'},
        {"verb": "health.check", "risk": "none", "reversible": True, "autonomous": False,
         "summary": "run a service health check now",
         "args": "{}"},
        {"verb": "overseerr_request", "risk": "low", "reversible": True, "autonomous": False,
         "summary": "request a title for the media library",
         "args": '{"media_type": "movie|tv", "media_id": N, "title": "..."}'},
        {"verb": "docker.update", "risk": "high", "reversible": False, "autonomous": False,
         "summary": "update one container image (bounces the container)",
         "args": '{"name": "...", "image": "..."}'},
    ],
    "ha_allowlist": {
        "services": ["climate.set_temperature", "scene.turn_on", "script.turn_on", "update.install"],
        "domains": ["light", "media_player", "switch"],
    },
}

CASES: dict[str, list[tuple[dict[str, Any], str | None]]] = {
    "authoring.skill_upsert": [
        ({"name": "Tide notes", "content": "# Tides\nhigh at noon"}, None),
        ({"name": "", "content": "c"}, "skill name required"),
        ({"name": "X", "content": "  "}, "skill content required"),
    ],
    "ha.service": [
        ({"domain": "light", "service": "turn_on", "data": {"entity_id": "light.desk"}}, None),
        ({"domain": "lock", "service": "unlock"}, "lock.unlock is not allowlisted"),
        ({"domain": "light"}, "ha.service needs domain and service"),
    ],
    "knowledge.set": [
        ({"type": "appliance", "name": "Heater", "attrs": {"watts": 1500}}, None),
        ({"type": "appliance"}, "knowledge.set needs type and name"),
        ({"name": "Heater"}, "knowledge.set needs type and name"),
    ],
    "knowledge.delete": [
        ({"entity_id": "appliance:heater"}, None),
        ({}, "knowledge.delete needs entity_id or type+name"),
        ({"type": "appliance"}, "knowledge.delete needs entity_id or type+name"),
    ],
    "knowledge.reverify": [
        ({"entity_id": "appliance:heater"}, None),
        ({}, "knowledge.reverify needs entity_id"),
        ({"entity_id": ""}, "knowledge.reverify needs entity_id"),
    ],
    "knowledge.promote": [
        ({"type": "appliance", "schema": {"required": ["brand", "model"]}}, None),
        ({"type": "appliance"}, "knowledge.promote needs type and schema"),
        ({"schema": {"required": []}}, "knowledge.promote needs type and schema"),
    ],
    "kitchen.grocy_adjust": [
        ({"product_id": 3, "op": "consume", "amount": 2}, None),
        ({"product_id": 3, "op": "nope", "amount": 1}, "op must be add or consume"),
        ({"op": "add", "amount": 1}, "kitchen.grocy_adjust needs product_id"),
        ({"product_id": 3, "op": "add"}, "kitchen.grocy_adjust needs amount"),
    ],
    "kitchen.mealie_import": [
        ({"url": "https://recipes.example/pasta"}, None),
        ({}, "kitchen.mealie_import needs url"),
        ({"url": ""}, "kitchen.mealie_import needs url"),
    ],
    "health.check": [
        ({}, None),
        ({"anything": 1}, None),
        ({"target": "x"}, None),
    ],
    "overseerr_request": [
        ({"media_type": "movie", "media_id": 603, "title": "The Matrix"}, None),
        ({"media_type": "book", "media_id": 1}, "overseerr_request needs media_type movie|tv"),
        ({"media_type": "tv"}, "overseerr_request needs media_id"),
    ],
    "docker.update": [
        ({"name": "radarr", "image": "x/radarr:latest"}, None),
        ({}, "docker.update needs name or image"),
        ({"name": "", "image": ""}, "docker.update needs name or image"),
    ],
}

PREVIEWS: dict[str, str] = {
    "authoring.skill_upsert": "Author skill 'Tide notes' (20 chars). Opens: # Tides",
    "ha.service": "Call light.turn_on on light.desk with {'entity_id': 'light.desk'}",
    "knowledge.set": "Record appliance 'Heater': {'watts': 1500}",
    "knowledge.delete": "Delete appliance:heater",
    "knowledge.reverify": "Re-verify appliance:heater (stamp last_verified = now)",
    "knowledge.promote": "Codify the 'appliance' type's schema (required: brand, model)",
    "kitchen.grocy_adjust": "Grocy consume 2 of product 3",
    "kitchen.mealie_import": "Import the recipe at https://recipes.example/pasta into Mealie (structured)",
    "health.check": "Run a read-only server/home health check",
    "overseerr_request": "Request The Matrix (movie) to the media library",
    "docker.update": "Update container radarr (x/radarr:latest). Pull the new image and recreate it",
}

AUTONOMOUS: dict[str, bool] = {
    "authoring.skill_upsert": False, "ha.service": False, "knowledge.set": False,
    "knowledge.delete": False, "knowledge.reverify": False, "knowledge.promote": False,
    "kitchen.grocy_adjust": False, "kitchen.mealie_import": True, "health.check": False,
    "overseerr_request": False, "docker.update": False,
}

JOB_TABLE: dict[str, tuple[str, str]] = {
    "pulse": ("Pulse briefing run", "0 5 * * *"),
    "home_model": ("Home model refresh", "30 3 * * *"),
    "home_reconcile": ("Home map reconcile", "0 3 * * *"),
    "home_digest": ("Home rhythm digest", "0 2 * * *"),
    "conversation_extract": ("Conversation extraction into the Profile Graph", "45 4 * * *"),
    "weight_fit": ("Ranking weight fit from feedback", "30 4 * * 0"),
    "knowledge_groom": ("Knowledge store grooming", "0 4 * * *"),
}

HOME_GATE = "requires the home_assistant integration with its home_modeling feature enabled"

GATES_OFF: dict[str, str | None] = {
    "pulse": None, "home_model": HOME_GATE, "home_reconcile": HOME_GATE, "home_digest": HOME_GATE,
    "conversation_extract": None, "weight_fit": None, "knowledge_groom": None,
}


def test_main_is_the_composition_root() -> None:
    assert "actions" in main.CAPABILITIES


def test_registry_response_is_pinned() -> None:
    assert asyncio.run(actions.registry()) == REGISTRY_RESPONSE


@pytest.mark.parametrize("verb", VERBS)
def test_validators_are_pinned(verb: str) -> None:
    validate = action_spec.SPEC[verb]["validate"]
    assert [validate(args) for args, _ in CASES[verb]] == [want for _, want in CASES[verb]]


@pytest.mark.parametrize("verb", VERBS)
def test_previews_are_pinned(verb: str) -> None:
    args = CASES[verb][0][0]
    assert action_spec.SPEC[verb]["preview"](args) == PREVIEWS[verb]


def test_autonomy_is_pinned() -> None:
    assert {verb: action_spec.is_autonomous(verb) for verb in VERBS} == AUTONOMOUS


def test_spec_order_is_pinned() -> None:
    assert list(action_spec.SPEC) == VERBS


def test_executors_cover_every_verb() -> None:
    assert set(actions.EXECUTORS) == set(VERBS)


def test_job_order_is_pinned() -> None:
    assert [job for job in scheduler._registry() if job in JOB_TABLE] == JOBS


def test_job_labels_and_crons_are_pinned() -> None:
    table = scheduler._registry()
    assert {job: (table[job][0], table[job][1]) for job in JOBS} == JOB_TABLE


def test_job_gates_with_home_modeling_off(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(integrations, "feature_enabled", lambda iid, fid: False)
    assert {job: scheduler._gate_reason(job) for job in JOBS} == GATES_OFF


def test_job_gates_with_home_modeling_on(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(integrations, "feature_enabled", lambda iid, fid: True)
    assert {job: scheduler._gate_reason(job) for job in JOBS} == {job: None for job in JOBS}
