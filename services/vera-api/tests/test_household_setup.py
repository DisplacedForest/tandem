import base64
import json
import time

import pytest
from pydantic import ValidationError

from routers.household import Gateway
from routers.household_events import EVENT, Events
from routers.household_store import Denied, Store


@pytest.fixture
def setup_gateway(tmp_path):
    store = Store(str(tmp_path / "gateway.db"))
    store.enroll("alpha")
    store.enroll("beta")
    deliveries = []

    def transport(url, body, headers):
        value = json.loads(body)
        if value.get("type") == "verification":
            return 200, json.dumps({"challenge": value["challenge"]}).encode()
        deliveries.append(value)
        return 202, b""

    events = Events(store, transport)
    secret = "whsec_" + base64.b64encode(b"synthetic-setup-test-only-key-12345").decode()
    delivery = {"mode": "webhook", "url": "https://callback.example/events", "secret": secret}
    return store, events, delivery, deliveries


def test_setup_requires_subscription_and_creates_no_identity_or_pair(setup_gateway):
    store, events, delivery, _ = setup_gateway
    with pytest.raises(Denied):
        store.setup_check("alpha", "one")
    events.subscribe("alpha", EVENT, {}, delivery)
    message = store.setup_check("alpha", "one")
    assert Store(store.path).setup_check("alpha", "one") == message
    with store.tx() as db:
        assert db.execute("SELECT count(*) FROM members").fetchone()[0] == 2
        assert db.execute("SELECT count(*) FROM inbox_endpoints").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM pairs").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM outbox").fetchone()[0] == 1
    assert store.inbox("beta") == []
    content = store.inbox("alpha")[0]
    assert content["sender"] == content["recipient"] == "alpha"
    assert content["id"] == message and content["grants_tool_authority"] is False
    assert "synthetic test content" in content["body"]


def test_setup_receipt_delivery_and_processing_stay_separate(setup_gateway):
    store, events, delivery, deliveries = setup_gateway
    events.subscribe("alpha", EVENT, {}, delivery)
    message = store.setup_check("alpha", "one")
    assert events.tick()
    assert deliveries[0]["data"] == {"message_id": message}
    status = store.status("alpha", message)
    assert status["webhook_receipts"] == 1
    assert status["delivered"] is None and status["processed"] is None
    with pytest.raises(Denied):
        store.acknowledge("beta", message, "delivered")
    with pytest.raises(Denied):
        store.status("beta", message)
    with pytest.raises(ValueError):
        store.acknowledge("alpha", message, "processed")
    store.acknowledge("alpha", message, "delivered")
    store.acknowledge("alpha", message, "processed")
    assert store.status("alpha", message)["processed"] is not None


def test_setup_is_rate_limited_and_cannot_be_forwarded_as_a_reply(setup_gateway):
    store, events, delivery, _ = setup_gateway
    events.subscribe("alpha", EVENT, {}, delivery)
    message = store.setup_check("alpha", "one")
    with pytest.raises(Denied):
        store.setup_check("alpha", "two")
    pair = store.pair("alpha", "beta", ["message"])
    store.consent("beta", pair, True)
    with pytest.raises(Denied):
        store.send("alpha", pair, "message", "reply", "reply", parent=message)


def test_setup_stops_on_revocation_and_expiry(setup_gateway):
    store, events, delivery, deliveries = setup_gateway
    sub = events.subscribe("alpha", EVENT, {}, delivery)
    with store.tx() as db:
        db.execute("UPDATE subscriptions SET expires=? WHERE id=?", (time.time() - 1, sub["id"]))
    with pytest.raises(Denied):
        store.setup_check("alpha", "one")
    events.subscribe("alpha", EVENT, {}, delivery)
    store.setup_check("alpha", "one")
    store.disable("alpha")
    assert events.tick()
    assert deliveries == []
    with pytest.raises(Denied):
        store.setup_check("alpha", "one")


def test_setup_rpc_uses_authenticated_owner_and_rejects_arbitrary_content(setup_gateway):
    store, events, delivery, _ = setup_gateway
    events.subscribe("alpha", EVENT, {}, delivery)
    gateway = Gateway(store, lambda _: "alpha", events)
    for extra in ({"actor": "beta"}, {"peer": "beta"}, {"body": "private text"}):
        with pytest.raises(ValidationError):
            gateway.tool("alpha", "inbox_setup_check", {"dedup": "one", **extra})
    result = gateway.dispatch("alpha", "tools/call", {"name": "inbox_setup_check", "arguments": {"dedup": "one"}, "_meta": {"actor": "beta"}})
    assert json.loads(result["content"][0]["text"])["processing_confirmed"] is False
    assert len(store.inbox("alpha")) == 1 and store.inbox("beta") == []
    with pytest.raises(Denied):
        Gateway(store, lambda _: "alpha").tool("alpha", "inbox_setup_check", {"dedup": "one"})
