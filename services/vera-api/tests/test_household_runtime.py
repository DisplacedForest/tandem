import asyncio
import base64
import json
import os
import sqlite3
import socket
import subprocess
import sys
import time
import threading
from pathlib import Path
from unittest.mock import Mock, patch

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers.household_gateway import Gateway, router
from routers.household_auth import EndpointKeys
from routers.household_events import Events, PinnedTLSConnection
from routers.household_runtime import configured_gateway, lifespan, worker
from routers.household_gateway_store import Denied, Store

ALPHA = "a" * 43
BETA = "b" * 43


@pytest.fixture
def configured(tmp_path, monkeypatch):
    private = tmp_path / "private"
    private.mkdir(mode=0o700)
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"database": str(private / "gateway.db"), "callback_hosts": []}))
    monkeypatch.setenv("HOUSEHOLD_CONFIG_PATH", str(config))
    gateway = configured_gateway()
    keys = EndpointKeys(gateway.store)
    keys.provision("alpha", ALPHA)
    keys.provision("beta", BETA)
    return gateway, keys, config


def test_endpoint_binding_expiration_rotation_and_restart(configured):
    gateway, keys, _ = configured
    assert gateway.principal("Bearer " + ALPHA, "alpha") == "alpha"
    for endpoint, key in (("beta", ALPHA), ("alpha", BETA), (None, ALPHA), ("unknown", ALPHA)):
        with pytest.raises(Denied):
            gateway.principal("Bearer " + key, endpoint)
    with keys.store.tx() as db:
        stored = db.execute("SELECT key_hash FROM inbox_endpoints WHERE endpoint='alpha'").fetchone()[0]
        assert ALPHA not in stored
    replacement = "c" * 43
    keys.rotate("alpha", replacement)
    assert EndpointKeys(Store(keys.store.path)).verify("alpha", ALPHA) is None
    assert keys.verify("alpha", replacement) == "alpha"
    with keys.store.tx() as db:
        db.execute("UPDATE inbox_endpoints SET expires=0 WHERE endpoint='alpha'")
    assert keys.verify("alpha", replacement) is None
    with pytest.raises(Denied):
        gateway.store.inbox("alpha")
    keys.rotate("alpha", ALPHA)
    assert keys.verify("alpha", ALPHA) == "alpha"


def test_expired_peer_cannot_be_read_but_can_be_revoked(configured):
    gateway, keys, _ = configured
    pair = gateway.store.pair("alpha", "beta", ["message"])
    gateway.store.consent("beta", pair, True)
    gateway.store.send("alpha", pair, "message", "Synthetic", "expiry")
    with keys.store.tx() as db:
        db.execute("UPDATE inbox_endpoints SET expires=0 WHERE endpoint='alpha'")
    assert gateway.store.inbox("beta") == []
    gateway.store.consent("beta", pair, False)
    assert gateway.store.pairs("beta")[0]["state"] == "revoked"


def test_revoke_stops_sharing_and_cancels_outbox(configured):
    gateway, keys, _ = configured
    pair = gateway.store.pair("alpha", "beta", ["message"])
    gateway.store.consent("beta", pair, True)
    gateway.store.send("alpha", pair, "message", "Synthetic", "key")
    keys.revoke("alpha")
    assert keys.verify("alpha", ALPHA) is None
    assert gateway.store.inbox("beta") == []
    with pytest.raises(Denied):
        keys.rotate("alpha", "z" * 43)


def test_http_local_endpoint_without_desktop_app(configured):
    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    with TestClient(app) as client:
        request = {"jsonrpc": "2.0", "id": 1, "method": "server/discover"}
        auth = {"Authorization": "Bearer " + ALPHA}
        assert client.post("/household/inboxes/alpha/mcp", json=request, headers=auth).status_code == 200
        assert client.post("/household/inboxes/beta/mcp", json=request, headers=auth).status_code == 401
        assert client.post("/household/mcp", json=request, headers=auth).status_code == 401
        assert client.post("/household/mcp?endpoint=alpha", json=request, headers=auth).status_code == 401
        assert client.post("/household/inboxes/alpha/mcp", json=request).status_code == 401
    assert app.state.household_gateway is None


def test_runtime_fails_closed_for_invalid_config(configured, monkeypatch):
    _, _, path = configured
    path.write_text('{"database":"relative-path"}')
    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    with TestClient(app) as client:
        assert client.post('/household/inboxes/alpha/mcp').status_code == 503
    monkeypatch.delenv("HOUSEHOLD_CONFIG_PATH")
    assert configured_gateway() is None


def test_callback_hosts_are_explicit(configured):
    _, _, path = configured
    raw = json.loads(path.read_text())
    for hosts in (["*.example.com"], ["localhost"], ["https://callback.example"], [123], "callback.example"):
        path.write_text(json.dumps(dict(raw, callback_hosts=hosts)))
        with pytest.raises(ValueError):
            configured_gateway()


def test_lifespan_delivers_durable_event_without_claiming_processing(configured, monkeypatch):
    gateway, _, path = configured
    raw = json.loads(path.read_text())
    path.write_text(json.dumps(dict(raw, callback_hosts=["callback.example"])))
    received = threading.Event()
    def transport(url, body, headers):
        payload = json.loads(body)
        if payload.get("type") == "verification":
            return 200, json.dumps({"challenge": payload["challenge"]}).encode()
        assert set(payload["data"]) == {"message_id"}
        received.set()
        return 202, b""
    monkeypatch.setattr("routers.household_runtime.PublicHTTPS", lambda _: transport)
    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    with TestClient(app) as client:
        def call(endpoint, key, method, params):
            response = client.post("/household/inboxes/" + endpoint + "/mcp", headers={"Authorization": "Bearer " + key}, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
            assert response.status_code == 200
            payload = response.json()
            assert "error" not in payload, payload
            return payload["result"]
        def tool(endpoint, key, name, arguments):
            return json.loads(call(endpoint, key, "tools/call", {"name": name, "arguments": arguments})["content"][0]["text"])
        pair = tool("alpha", ALPHA, "pair_offer", {"peer": "beta", "scopes": ["summary"]})["pair_id"]
        tool("beta", BETA, "pair_consent", {"pair_id": pair, "accept": True})
        call("beta", BETA, "events/subscribe", {"name": "household.message.created", "delivery": {"mode": "webhook", "url": "https://callback.example/hook", "secret": "whsec_" + base64.b64encode(b"s" * 32).decode()}})
        message = tool("alpha", ALPHA, "message_share", {"pair_id": pair, "kind": "summary", "body": "Synthetic summary", "dedup": "integration"})["message_id"]
        assert received.wait(3)
    status = gateway.store.status("alpha", message)
    assert status["webhook_receipts"] == 1
    assert status["delivered"] is None and status["processed"] is None
    gateway.store.acknowledge("beta", message, "delivered")
    gateway.store.acknowledge("beta", message, "processed")
    assert Store(gateway.store.path).status("alpha", message)["processed"] is not None


def test_worker_recovers_then_stops_without_canceling_inflight(configured):
    gateway, _, _ = configured
    calls = []
    stop = asyncio.Event()
    def tick():
        calls.append(True)
        if len(calls) == 1:
            raise sqlite3.OperationalError("synthetic lock")
        stop.set()
    gateway.events = Mock(tick=tick)
    asyncio.run(worker(gateway, stop))
    assert len(calls) == 2


def test_pinned_tls_always_checks_original_hostname():
    context = Mock()
    raw = Mock()
    tls = Mock()
    context.wrap_socket.return_value = tls
    with patch("socket.socket", return_value=raw), patch("ssl.create_default_context", return_value=context):
        connection = PinnedTLSConnection("callback.example", ("8.8.8.8", 443), 2, 1, 6)
        connection.connect()
        raw.connect.assert_called_once_with(("8.8.8.8", 443))
        context.wrap_socket.assert_called_once_with(raw, server_hostname="callback.example", do_handshake_on_connect=False)
        tls.do_handshake.assert_called_once()
        connection.expire()
        tls.shutdown.assert_called_once()
        with pytest.raises(TimeoutError):
            connection.connect()


def test_admin_never_prints_key_and_requires_explicit_consent(tmp_path):
    private = tmp_path / "private"
    private.mkdir(mode=0o700)
    database = private / "gateway.db"
    output = private / "alpha.key"
    script = Path(__file__).resolve().parents[1] / "household_admin.py"
    args = [sys.executable, str(script), "--database", str(database), "provision", "--endpoint", "alpha", "--key-output", str(output)]
    denied = subprocess.run(args, capture_output=True, text=True)
    assert denied.returncode != 0
    assert not database.exists()
    result = subprocess.run(args + ["--consent-confirmed"], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    key = output.read_text().strip()
    assert key not in result.stdout + result.stderr
    assert output.stat().st_mode & 0o777 == 0o600
    assert EndpointKeys(Store(str(database))).verify("alpha", key) == "alpha"
    again = subprocess.run(args + ["--consent-confirmed"], capture_output=True, text=True)
    assert again.returncode != 0
    assert output.read_text().strip() == key


def test_deadline_interrupts_response_owned_socket():
    client, peer = socket.socketpair()
    connection = PinnedTLSConnection("callback.example", (), 2, 1, 6)
    connection.sock = client
    connection.active_socket = client
    client.settimeout(2)
    stopped = threading.Event()
    def drip():
        try:
            peer.recv(4096)
            peer.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
            while not stopped.wait(0.02):
                peer.sendall(b"x")
        except OSError:
            pass
        finally:
            peer.close()
    thread = threading.Thread(target=drip)
    thread.start()
    timer = threading.Timer(0.15, connection.expire)
    started = time.monotonic()
    try:
        connection.request("POST", "/", b"synthetic")
        with connection.getresponse() as response:
            assert connection.sock is None
            timer.start()
            response.read(4097)
        assert connection.expired.is_set()
        assert time.monotonic() - started < 1
    finally:
        stopped.set()
        timer.cancel()
        connection.close()
        thread.join(timeout=1)
