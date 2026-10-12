import json
import re
import time
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers.household_gateway import Gateway, router as private_router
from routers.household_auth import EndpointKeys
from routers.household_oauth import COOKIE, SCOPE, OAuth, OAuthError, challenge, lifespan, router
from routers.household_gateway_store import Store

ORIGIN = "https://inbox.example.com"
REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect"
VERIFIER = "v" * 43


@pytest.fixture
def setup(tmp_path):
    store = Store(str(tmp_path / "gateway.db"))
    keys = EndpointKeys(store)
    keys.provision("alpha", "a" * 43)
    keys.provision("beta", "b" * 43)
    oauth = OAuth(store, ORIGIN)
    gateway = Gateway(store, lambda _: None, endpoint_verify=keys.verify, event_discovery=True)
    app = FastAPI()
    app.state.household_gateway = gateway
    app.state.household_oauth = oauth
    app.include_router(router)
    app.include_router(private_router)
    with TestClient(app, base_url=ORIGIN) as client:
        yield oauth, client, keys


def authorization(oauth, client=None):
    client = client or oauth.register({"redirect_uris": [REDIRECT]})["client_id"]
    return {"client_id": client, "redirect_uri": REDIRECT, "response_type": "code", "scope": SCOPE, "state": "opaque-state", "resource": oauth.resource, "code_challenge": challenge(VERIFIER), "code_challenge_method": "S256"}


def code(oauth, endpoint="alpha", data=None):
    data = data or authorization(oauth)
    session = oauth.authorize(data)
    target = oauth.consent(session, session, oauth.enroll(endpoint))
    result = parse_qs(urlsplit(target).query)
    assert result["iss"] == [ORIGIN]
    assert result["state"] == [data["state"]]
    return {"grant_type": "authorization_code", "client_id": data["client_id"], "redirect_uri": data["redirect_uri"], "resource": oauth.resource, "code": result["code"][0], "code_verifier": VERIFIER}


def tokens(oauth, endpoint="alpha"):
    request = code(oauth, endpoint)
    result = oauth.token(request)
    return result, request["client_id"]


def refresh(oauth, result, client):
    return {"grant_type": "refresh_token", "client_id": client, "resource": oauth.resource, "refresh_token": result["refresh_token"]}


def test_discovery_and_authentication_challenge(setup):
    oauth, client, _ = setup
    for path in ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"):
        resource = client.get(path).json()
        assert resource["resource"] == ORIGIN + "/mcp"
        assert resource["authorization_servers"] == [ORIGIN]
    metadata = client.get("/.well-known/oauth-authorization-server").json()
    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["authorization_response_iss_parameter_supported"] is True
    response = client.post("/mcp", json={})
    assert response.status_code == 401
    assert ORIGIN + "/.well-known/oauth-protected-resource/mcp" in response.headers["www-authenticate"]
    assert client.get("/mcp").status_code == 401
    assert client.post("/mcp", headers={"Authorization": "Bearer " + "a" * 43}, json={}).status_code == 401


@pytest.mark.parametrize("redirect", ["https://evil.example.com/callback", REDIRECT + "?foo=bar", REDIRECT + "#fragment", "https://chatgpt.com.evil.example.com/connector_platform_oauth_redirect", "http://chatgpt.com/connector_platform_oauth_redirect", "https://chatgpt.com/connector/oauth/../other", 1, None])
def test_redirect_registration_is_bounded(setup, redirect):
    _, client, _ = setup
    response = client.post("/oauth/register", json={"redirect_uris": [redirect]})
    assert response.status_code == 400
    assert response.json() == {"error": "invalid_redirect_uri"}


def test_registration_persists_and_validates_metadata(setup):
    oauth, client, _ = setup
    response = client.post("/oauth/register", json={"redirect_uris": [REDIRECT]})
    assert response.status_code == 201
    assert response.json()["token_endpoint_auth_method"] == "none"
    OAuth(oauth.store, ORIGIN).authorize(authorization(oauth, response.json()["client_id"]))
    for field, value in (("token_endpoint_auth_method", "client_secret_basic"), ("grant_types", ["implicit"]), ("response_types", ["token"]), ("scope", "admin")):
        assert client.post("/oauth/register", json={"redirect_uris": [REDIRECT], field: value}).status_code == 400
    assert client.post("/oauth/register", json={"redirect_uris": ["https://chatgpt.com/connector/oauth/callback_1"]}).status_code == 201


def test_full_browser_consent_flow_and_http_exchange(setup):
    oauth, client, _ = setup
    data = authorization(oauth)
    response = client.get("/oauth/authorize", params=data)
    assert response.status_code == 200
    assert "opaque-state" not in response.text
    assert "HttpOnly" in response.headers["set-cookie"]
    assert "Secure" in response.headers["set-cookie"]
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
    csrf = re.search('name="csrf" value="([^"]+)"', response.text)[1]
    response = client.post("/oauth/authorize", data={"csrf": csrf, "enrollment": oauth.enroll("beta"), "action": "connect"}, headers={"Origin": ORIGIN}, follow_redirects=False)
    assert response.status_code == 303
    grant_code = parse_qs(urlsplit(response.headers["location"]).query)["code"][0]
    response = client.post("/oauth/token", data={"grant_type": "authorization_code", "client_id": data["client_id"], "redirect_uri": REDIRECT, "resource": oauth.resource, "code": grant_code, "code_verifier": VERIFIER})
    assert response.status_code == 200
    token = response.json()["access_token"]
    assert oauth.principal("Bearer " + token) == "beta"
    rpc = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "inbox_read", "arguments": {}}}
    assert "result" in client.post("/mcp", json=rpc, headers={"Authorization": "Bearer " + token}).json()
    assert client.get("/mcp", headers={"Authorization": "Bearer " + token}).status_code == 405
    assert client.post("/household/inboxes/alpha/mcp", json=rpc, headers={"Authorization": "Bearer " + token}).status_code == 401
    assert "result" in client.post("/household/inboxes/alpha/mcp", json=rpc, headers={"Authorization": "Bearer " + "a" * 43}).json()


@pytest.mark.parametrize("field,value", [("resource", "https://other.example.com/mcp"), ("redirect_uri", REDIRECT + "?x=1"), ("client_id", "other"), ("code_challenge_method", "plain"), ("code_challenge", "short"), ("scope", "admin"), ("response_type", "token"), ("state", "")])
def test_authorization_binding(setup, field, value):
    oauth, _, _ = setup
    data = authorization(oauth)
    data[field] = value
    with pytest.raises(OAuthError):
        oauth.authorize(data)


@pytest.mark.parametrize("field,value", [("resource", "https://other.example.com/mcp"), ("redirect_uri", REDIRECT + "?x=1"), ("client_id", "other"), ("code_verifier", "z" * 43), ("scope", "admin")])
def test_exchange_binding_and_single_use(setup, field, value):
    oauth, _, _ = setup
    request = code(oauth)
    with pytest.raises(OAuthError):
        oauth.token(request | {field: value})
    result = oauth.token(request)
    assert oauth.principal("Bearer " + result["access_token"]) == "alpha"
    with pytest.raises(OAuthError):
        oauth.token(request)


def test_enrollment_single_use_attempt_limit_and_csrf(setup):
    oauth, client, _ = setup
    enrollment = oauth.enroll("alpha")
    session = oauth.authorize(authorization(oauth))
    with pytest.raises(OAuthError):
        oauth.consent(session, "wrong", enrollment)
    for _ in range(5):
        with pytest.raises(OAuthError):
            oauth.consent(session, session, "wrong")
    with pytest.raises(OAuthError):
        oauth.consent(session, session, enrollment)
    fresh = oauth.authorize(authorization(oauth))
    oauth.consent(fresh, fresh, enrollment)
    other = oauth.authorize(authorization(oauth))
    with pytest.raises(OAuthError):
        oauth.consent(other, other, enrollment)
    data = {"csrf": other, "enrollment": oauth.enroll("alpha"), "action": "connect"}
    assert client.post("/oauth/authorize", data=data, headers={"Origin": "https://evil.example.com"}).status_code == 403
    assert client.post("/oauth/authorize", data=data, headers={"Origin": ORIGIN}).status_code == 403


def test_refresh_rotation_replay_revokes_family(setup):
    oauth, _, _ = setup
    result, client = tokens(oauth)
    rotated = oauth.token(refresh(oauth, result, client))
    assert rotated["refresh_token"] != result["refresh_token"]
    assert oauth.principal("Bearer " + rotated["access_token"]) == "alpha"
    with pytest.raises(OAuthError):
        oauth.token(refresh(oauth, result, client))
    for token in (result, rotated):
        with pytest.raises(OAuthError):
            oauth.principal("Bearer " + token["access_token"])
        with pytest.raises(OAuthError):
            oauth.token(refresh(oauth, token, client))


def test_revocation_cannot_cross_clients_or_inboxes(setup):
    oauth, _, _ = setup
    alpha, alpha_client = tokens(oauth)
    beta, beta_client = tokens(oauth, "beta")
    oauth.revoke({"client_id": beta_client, "token": alpha["access_token"]})
    assert oauth.principal("Bearer " + alpha["access_token"]) == "alpha"
    with pytest.raises(OAuthError):
        oauth.token(refresh(oauth, alpha, beta_client))
    oauth.revoke({"client_id": alpha_client, "token": alpha["refresh_token"]})
    with pytest.raises(OAuthError):
        oauth.principal("Bearer " + alpha["access_token"])
    assert oauth.principal("Bearer " + beta["access_token"]) == "beta"


@pytest.mark.parametrize("action", ["rotate", "revoke", "expire", "disable"])
def test_endpoint_changes_invalidate_grants_enrollment_and_codes(setup, action):
    oauth, _, keys = setup
    alpha, client = tokens(oauth)
    pending_code = code(oauth)
    pending = oauth.authorize(authorization(oauth))
    enrollment = oauth.enroll("alpha")
    if action == "rotate":
        keys.rotate("alpha", "c" * 43)
    elif action == "revoke":
        keys.revoke("alpha")
    elif action == "disable":
        oauth.store.disable("alpha")
    else:
        with oauth.store.tx() as db:
            db.execute("UPDATE inbox_endpoints SET expires=0 WHERE endpoint='alpha'")
    for operation in (lambda: oauth.principal("Bearer " + alpha["access_token"]), lambda: oauth.token(refresh(oauth, alpha, client)), lambda: oauth.token(pending_code), lambda: oauth.consent(pending, pending, enrollment)):
        with pytest.raises(OAuthError):
            operation()


def test_expiry_and_hash_only_storage(setup):
    oauth, _, _ = setup
    result, client = tokens(oauth)
    assert 0 < result["expires_in"] <= 3600
    enrollment = oauth.enroll("beta")
    with oauth.store.tx() as db:
        dump = "\n".join(db.iterdump())
        assert result["access_token"] not in dump
        assert result["refresh_token"] not in dump
        assert enrollment not in dump
        db.execute("UPDATE oauth_tokens SET expires=0 WHERE kind='access'")
    with pytest.raises(OAuthError):
        oauth.principal("Bearer " + result["access_token"])
    rotated = oauth.token(refresh(oauth, result, client))
    with oauth.store.tx() as db:
        db.execute("UPDATE oauth_grants SET expires=0")
    with pytest.raises(OAuthError):
        oauth.token(refresh(oauth, rotated, client))


def test_malformed_requests_bounds_and_rate_limit(setup):
    oauth, client, _ = setup
    assert client.post("/oauth/register", content="x" * 8193, headers={"Content-Type": "application/json"}).status_code == 413
    assert client.post("/oauth/register", json=[]).status_code == 400
    assert client.post("/oauth/token", content="client_id=a&client_id=b", headers={"Content-Type": "application/x-www-form-urlencoded"}).status_code == 400
    assert client.get("/oauth/authorize?client_id=a&client_id=b").status_code == 400
    for _ in range(30):
        response = client.post("/oauth/register", json={"redirect_uris": [REDIRECT]})
    assert response.status_code == 429
    assert len(oauth.rates["register"]) <= 20


def test_disabled_and_invalid_configuration(tmp_path, monkeypatch):
    monkeypatch.delenv("HOUSEHOLD_PUBLIC_ORIGIN", raising=False)
    monkeypatch.delenv("HOUSEHOLD_CONFIG_PATH", raising=False)
    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    with TestClient(app) as client:
        assert client.post("/mcp").status_code == 404
        assert client.get("/.well-known/oauth-authorization-server").status_code == 404
    for origin in ("http://inbox.example.com", ORIGIN + "/", ORIGIN + "?x=1", "https://u:p@inbox.example.com", "https://inbox.example.com:443"):
        with pytest.raises(ValueError):
            OAuth(Store(str(tmp_path / "invalid.db")), origin)


def test_streamable_http_initialization_and_notifications(setup):
    oauth, client, _ = setup
    result, _ = tokens(oauth)
    headers = {"Authorization": "Bearer " + result["access_token"]}
    response = client.post("/mcp", headers=headers, json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}})
    assert response.json()["result"]["protocolVersion"] == "2025-06-18"
    for method in ("notifications/initialized", "notifications/cancelled"):
        response = client.post("/mcp", headers=headers, json={"jsonrpc": "2.0", "method": method, "params": {}})
        assert response.status_code == 202
        assert response.content == b""
    assert client.post("/mcp", headers=headers, json={"jsonrpc": "2.0", "id": 2, "method": "ping"}).json()["result"] == {}
    for rpc in ({"jsonrpc": "2.0", "method": "tools/list"}, {"jsonrpc": "2.0", "id": True, "method": "tools/list"}):
        assert "error" in client.post("/mcp", headers=headers, json=rpc).json()


def test_concurrent_code_redemption_has_one_winner(setup):
    from concurrent.futures import ThreadPoolExecutor

    oauth, _, _ = setup
    request = code(oauth)

    def redeem():
        try:
            return oauth.token(request)["access_token"]
        except OAuthError:
            return None

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: redeem(), range(2)))
    assert sum(value is not None for value in results) == 1


@pytest.mark.parametrize("table", ["oauth_enrollment", "oauth_pending", "oauth_codes", "oauth_clients"])
def test_short_lived_artifacts_expire(setup, table):
    oauth, _, _ = setup
    data = authorization(oauth)
    session = oauth.authorize(data)
    enrollment = oauth.enroll("alpha")
    request = code(oauth, data=data)
    if table == "oauth_enrollment":
        enrollment = oauth.enroll("alpha")
    with oauth.store.tx() as db:
        db.execute(f"UPDATE {table} SET expires=0")
    with pytest.raises(OAuthError):
        if table in ("oauth_enrollment", "oauth_pending"):
            oauth.consent(session, session, enrollment)
        else:
            oauth.token(request)


def test_registration_churn_preserves_active_flow_and_grants(setup):
    oauth, _, _ = setup
    result, connected = tokens(oauth)
    pending_data = authorization(oauth)
    pending = oauth.authorize(pending_data)
    code_request = code(oauth)
    for _ in range(256):
        oauth.register({"redirect_uris": [REDIRECT]})
    assert oauth.principal("Bearer " + result["access_token"]) == "alpha"
    oauth.token(refresh(oauth, result, connected))
    oauth.token(code_request)
    oauth.consent(pending, pending, oauth.enroll("alpha"))
    with oauth.store.tx() as db:
        assert db.execute("SELECT count(*) FROM oauth_clients").fetchone()[0] == 128


def test_dcr_grant_order_and_non_ascii_csrf(setup):
    oauth, _, _ = setup
    for grants in (["refresh_token", "authorization_code"], ["authorization_code"]):
        oauth.register({"redirect_uris": [REDIRECT], "grant_types": grants})
    session = oauth.authorize(authorization(oauth))
    with pytest.raises(OAuthError) as failure:
        oauth.consent(session, "invalid-☃", oauth.enroll("alpha"))
    assert failure.value.status == 403
