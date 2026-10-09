import json

from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers.household import Gateway, router
from routers.household_store import Store


def test_http_authentication_and_protocol(tmp_path):
    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)
    rpc = {"jsonrpc": "2.0", "id": 1, "method": "server/discover"}
    assert client.post('/household/mcp', json=rpc).status_code == 503
    store = Store(str(tmp_path / "gateway.db"))
    store.enroll("alpha")
    store.enroll("beta")
    app.state.household_gateway = Gateway(store, lambda token: {"test-alpha": "alpha", "test-beta": "beta"}.get(token))
    assert client.post('/household/mcp', json=rpc).status_code == 401
    assert client.post('/household/mcp', json=rpc, headers={"X-User-ID": "alpha"}).status_code == 401
    headers = {"Authorization": "Bearer test-alpha"}
    def call(method, params=None, auth=headers):
        return client.post('/household/mcp', json={**rpc, "method": method, "params": params or {}}, headers=auth)
    assert call("server/discover").json()["result"]["supportedVersions"] == ["2026-07-28"]
    tools = call("tools/list").json()["result"]["tools"]
    assert len(tools) == 8
    assert call("events/list").json()["result"] == {"events": []}
    meta = {"actor": "beta", "authority": "admin", "progressToken": "synthetic"}
    assert json.loads(call("tools/call", {"name": "inbox_read", "_meta": meta}).json()["result"]["content"][0]["text"]) == {"messages": []}
    assert "error" in call("tools/call", {"name": "inbox_read", "_meta": []}).json()
    assert "error" in call("tools/call", {"name": "inbox_read", "arguments": {"actor": "beta"}}).json()
    offer = call("tools/call", {"name": "pair_offer", "arguments": {"peer": "beta", "scopes": ["message"]}}).json()
    pair = json.loads(offer["result"]["content"][0]["text"])["pair_id"]
    assert "error" in call("tools/call", {"name": "pair_consent", "arguments": {"pair_id": pair, "accept": True}}).json()
    assert "result" in call("tools/call", {"name": "pair_consent", "arguments": {"pair_id": pair, "accept": True}}, {"Authorization": "Bearer test-beta"}).json()
    sent = call("tools/call", {"name": "message_share", "arguments": {"pair_id": pair, "kind": "message", "body": "Synthetic message", "dedup": "one"}}).json()
    assert "result" in sent
    assert client.post('/household/mcp', content=b'x'*32769, headers=headers).status_code == 413
    for invalid in ([], None, {"jsonrpc": "2.0", "id": True}, {**rpc, "params": []}):
        assert "error" in client.post('/household/mcp', json=invalid, headers=headers).json()
    store.disable("alpha")
    assert call("server/discover").status_code == 401


def test_event_errors_are_bounded_and_categorized(tmp_path):
    import base64
    from routers.household_events import Events
    app = FastAPI()
    app.include_router(router)
    store = Store(str(tmp_path / "gateway.db"))
    store.enroll("alpha")
    def timeout(*_):
        raise TimeoutError()
    events = Events(store, timeout)
    app.state.household_gateway = Gateway(store, lambda _: "alpha", events)
    client = TestClient(app)
    def call(params):
        return client.post('/household/mcp', headers={"Authorization": "Bearer synthetic"}, json={"jsonrpc": "2.0", "id": 1, "method": "events/subscribe", "params": params}).json()
    params = {"name": "household.message.created", "arguments": {}, "delivery": {"mode": "webhook", "url": "https://callback.example/events", "secret": "whsec_" + base64.b64encode(b"synthetic-only-key-0123456789").decode()}}
    result = call(params)
    assert result["error"]["code"] == -32015
    assert result["error"]["data"]["reason"] == "timeout"
    for delivery in (None, [], {"mode": "webhook", "url": 123}, dict(params["delivery"], secret=123)):
        assert call(dict(params, delivery=delivery))["error"]["code"] == -32602
