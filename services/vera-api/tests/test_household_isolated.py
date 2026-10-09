import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from routers.household_auth import EndpointKeys
from routers.household_store import Store


def test_isolated_entrypoint_imports_no_shared_api_runtime():
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run([sys.executable, "-c", "import sys,household_app; assert 'main' not in sys.modules; assert 'routers.scheduler' not in sys.modules; assert 'routers.home_events' not in sys.modules; assert 'data_root' not in sys.modules; assert 'routers.conversation_ingest' not in sys.modules"], cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_discovery_only_rejects_without_network_or_secret_storage(tmp_path, monkeypatch, caplog):
    from household_app import app
    private = tmp_path / "private"
    private.mkdir(mode=0o700)
    database = private / "gateway.db"
    config = private / "config.json"
    config.write_text(json.dumps({"database": str(database), "callback_hosts": [], "event_discovery": True}))
    os.chmod(config, 0o600)
    store = Store(str(database))
    key = "a" * 43
    EndpointKeys(store).provision("alpha", key)
    monkeypatch.setenv("HOUSEHOLD_CONFIG_PATH", str(config))
    with patch("socket.getaddrinfo", side_effect=AssertionError("No DNS permitted")), patch("routers.household_runtime.worker", side_effect=AssertionError("No delivery worker permitted")):
        with TestClient(app) as client:
            auth = {"Authorization": "Bearer " + key}
            def rpc(method, params=None):
                return client.post("/household/inboxes/alpha/mcp", headers=auth, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).json()
            assert client.get("/health").json() == {"ok": True}
            assert client.get("/docs").status_code == 404
            assert client.get("/pulse/cards").status_code == 404
            assert client.get("/home/state").status_code == 404
            assert "events" in rpc("server/discover")["result"]["capabilities"]
            assert len(rpc("events/list")["result"]["events"]) == 1
            secret = "whsec_synthetic-not-to-be-persisted"
            response = rpc("events/subscribe", {"_meta": {"actor": "another-owner"}, "name": "household.message.created", "delivery": {"mode": "webhook", "url": "https://callback.example/opaque?token=synthetic-private", "secret": secret}})
            assert response["error"]["code"] == -32015
            assert response["error"]["data"] == {"reason": "callback_not_approved", "callback_host": "callback.example"}
            assert "synthetic-private" not in json.dumps(response)
            assert secret not in json.dumps(response)
            assert "callback.example" in caplog.text
            assert "synthetic-private" not in caplog.text
            assert secret not in caplog.text
            assert app.state.household_gateway.events is None
    with store.tx() as db:
        assert db.execute("SELECT count(*) FROM subscriptions").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM outbox").fetchone()[0] == 0
    assert secret.encode() not in database.read_bytes()
    assert app.state.household_gateway is None


def test_isolated_health_is_unready_without_config(monkeypatch):
    from household_app import app
    monkeypatch.delenv("HOUSEHOLD_CONFIG_PATH", raising=False)
    with TestClient(app) as client:
        assert client.get("/health").status_code == 503
        assert client.post("/household/inboxes/alpha/mcp").status_code == 503
