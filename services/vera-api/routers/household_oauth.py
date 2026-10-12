import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from collections import deque
from contextlib import asynccontextmanager
from string import Template
from typing import Any, AsyncIterator
from urllib.parse import parse_qsl, urlencode, urlsplit

from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from .household_gateway import Gateway
from .household_events import CallbackError
from .household_runtime import lifespan as gateway_lifespan
from .household_gateway_store import Denied, Store

router = APIRouter()
SCOPE = "household/inbox"
COOKIE = "__Host-household-connect"
HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"}


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def random_value() -> str:
    return secrets.token_urlsafe(32)


def challenge(value: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(value.encode()).digest()).rstrip(b"=").decode()


def valid_redirect(value: Any) -> bool:
    return isinstance(value, str) and (value == "https://chatgpt.com/connector_platform_oauth_redirect" or re.fullmatch(r"https://chatgpt\.com/connector/oauth/[A-Za-z0-9_-]{1,128}", value) is not None)


class OAuthError(ValueError):
    def __init__(self, code: str = "invalid_request", status: int = 400):
        self.code = code
        self.status = status


class OAuth:
    def __init__(self, store: Store, origin: str):
        parsed = urlsplit(origin)
        if parsed.scheme != "https" or not parsed.hostname or parsed.netloc != parsed.hostname or parsed.path or parsed.query or parsed.fragment or not re.fullmatch(r"[a-z0-9.-]+", parsed.hostname):
            raise ValueError("Public origin must be a canonical HTTPS origin")
        self.store = store
        self.origin = origin
        self.resource = origin + "/mcp"
        self.lock = threading.Lock()
        self.rates: dict[str, deque[float]] = {}
        with store.tx() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS oauth_clients(id TEXT PRIMARY KEY, redirects TEXT NOT NULL, expires REAL NOT NULL, provisional INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS oauth_enrollment(hash TEXT PRIMARY KEY, endpoint TEXT NOT NULL, key_hash TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS oauth_secret(id INTEGER PRIMARY KEY CHECK (id = 1), value BLOB NOT NULL);
                DROP TABLE IF EXISTS oauth_pending;
                CREATE TABLE IF NOT EXISTS oauth_codes(hash TEXT PRIMARY KEY, payload TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS oauth_grants(id TEXT PRIMARY KEY, client TEXT NOT NULL, endpoint TEXT NOT NULL, key_hash TEXT NOT NULL, resource TEXT NOT NULL, expires REAL NOT NULL, revoked INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS oauth_tokens(hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE, kind TEXT NOT NULL, expires REAL NOT NULL, used INTEGER NOT NULL);
            """)
            if "provisional" not in {row[1] for row in db.execute("PRAGMA table_info(oauth_clients)")}:
                db.execute("ALTER TABLE oauth_clients ADD COLUMN provisional INTEGER NOT NULL DEFAULT 0")
            db.execute("INSERT OR IGNORE INTO oauth_secret VALUES (1, ?)", (secrets.token_bytes(32),))
            self.secret = bytes(db.execute("SELECT value FROM oauth_secret WHERE id=1").fetchone()[0])
            self.cleanup(db)

    def rate(self, route: str, limit: int = 120, key: str | None = None) -> None:
        now = time.monotonic()
        with self.lock:
            for stale in [name for name, queue in self.rates.items() if not queue or queue[-1] <= now - 60]:
                del self.rates[stale]
            buckets = [(route, limit * 10 if key is not None else limit)]
            if key is not None:
                buckets.append((route + ":" + key, limit))
            for name, cap in buckets:
                queue = self.rates.setdefault(name, deque())
                while queue and queue[0] <= now - 60:
                    queue.popleft()
                if len(queue) >= cap:
                    raise OAuthError("temporarily_unavailable", 429)
            for name, _ in buckets:
                self.rates[name].append(now)

    def secret_key(self, data: dict) -> str:
        candidates = [value for value in (data.get("refresh_token"), data.get("code"), data.get("token")) if isinstance(value, str) and value]
        if not candidates:
            return "anonymous"
        with self.store.tx() as db:
            for value in candidates:
                hashed = digest(value)
                if db.execute("SELECT 1 FROM oauth_tokens WHERE hash=? AND expires>?", (hashed, time.time())).fetchone() or db.execute("SELECT 1 FROM oauth_codes WHERE hash=? AND expires>?", (hashed, time.time())).fetchone():
                    return hashed
        return "anonymous"

    def bearer_key(self, authorization: str) -> str:
        if not authorization.startswith("Bearer ") or len(authorization) > 1024:
            return "anonymous"
        hashed = digest(authorization[7:])
        with self.store.tx() as db:
            row = db.execute("SELECT 1 FROM oauth_tokens WHERE hash=? AND kind='access' AND expires>?", (hashed, time.time())).fetchone()
        return hashed if row else "anonymous"

    def cleanup(self, db: sqlite3.Connection) -> None:
        db.execute("DELETE FROM oauth_tokens WHERE kind='access' AND expires<=?", (time.time(),))
        db.execute("DELETE FROM oauth_tokens WHERE grant_id IN (SELECT id FROM oauth_grants WHERE revoked=1 OR expires<=?)", (time.time(),))
        db.execute("""DELETE FROM oauth_tokens WHERE rowid IN (SELECT rowid FROM (
            SELECT rowid, kind, used, row_number() OVER (PARTITION BY grant_id, kind, used ORDER BY rowid DESC) AS position FROM oauth_tokens)
            WHERE kind='access' AND used=0 AND position>4)""")
        db.execute("""DELETE FROM oauth_grants WHERE id IN (SELECT id FROM (
            SELECT id, row_number() OVER (PARTITION BY endpoint ORDER BY rowid DESC) AS position FROM oauth_grants) WHERE position>8)""")
        for statement in (
            "DELETE FROM oauth_enrollment WHERE expires<=?",
            "DELETE FROM oauth_codes WHERE expires<=?",
            "DELETE FROM oauth_grants WHERE revoked=1 OR expires<=?",
            "DELETE FROM oauth_clients WHERE expires<=?",
        ):
            db.execute(statement, (time.time(),))
        db.execute("""UPDATE oauth_clients SET provisional=1, expires=min(expires, ?) WHERE provisional=0
            AND NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client=oauth_clients.id)
            AND NOT EXISTS (SELECT 1 FROM oauth_codes c WHERE json_extract(c.payload,'$.client_id')=oauth_clients.id)""", (time.time() + 600,))

    def room(self, db: sqlite3.Connection, table: str, limit: int) -> None:
        self.cleanup(db)
        if table == "oauth_clients":
            db.execute("DELETE FROM oauth_clients WHERE provisional=1 AND id IN (SELECT id FROM oauth_clients WHERE provisional=1 ORDER BY expires DESC, rowid DESC LIMIT -1 OFFSET ?)", (limit - 1,))
            return
        statements = {
            "oauth_enrollment": "SELECT count(*) FROM oauth_enrollment",
            "oauth_codes": "SELECT count(*) FROM oauth_codes",
            "oauth_grants": "SELECT count(*) FROM oauth_grants",
            "oauth_tokens": "SELECT count(*) FROM oauth_tokens WHERE used=0",
        }
        if db.execute(statements[table]).fetchone()[0] >= limit:
            raise OAuthError("temporarily_unavailable", 429)

    def endpoint(self, db: sqlite3.Connection, endpoint: str, snapshot: str | None = None) -> sqlite3.Row:
        row = db.execute("SELECT * FROM inbox_endpoints WHERE endpoint=?", (endpoint,)).fetchone()
        if not row or not row["enabled"] or row["expires"] <= time.time() or (snapshot is not None and not hmac.compare_digest(row["key_hash"], snapshot)):
            raise OAuthError("invalid_grant")
        try:
            self.store.require(db, row["principal"])
        except Denied as error:
            raise OAuthError("invalid_grant") from error
        return row

    def enroll(self, endpoint: str, ttl: int = 600) -> str:
        if type(ttl) is not int or not 1 <= ttl <= 600:
            raise ValueError("Enrollment expires within ten minutes")
        value = random_value()
        with self.store.tx() as db:
            row = self.endpoint(db, endpoint)
            db.execute("DELETE FROM oauth_enrollment WHERE endpoint=?", (endpoint,))
            self.room(db, "oauth_enrollment", 32)
            db.execute("INSERT INTO oauth_enrollment VALUES (?,?,?,?)", (digest(value), endpoint, row["key_hash"], min(time.time() + ttl, row["expires"])))
        return value

    def register(self, data: dict) -> dict:
        redirects = data.get("redirect_uris")
        if not isinstance(redirects, list) or not 1 <= len(redirects) <= 4 or not all(valid_redirect(value) for value in redirects) or len(set(redirects)) != len(redirects):
            raise OAuthError("invalid_redirect_uri")
        grants = data.get("grant_types", ["authorization_code", "refresh_token"])
        if not isinstance(grants, list) or not all(isinstance(value, str) for value in grants) or "authorization_code" not in grants or set(grants) - {"authorization_code", "refresh_token"}:
            raise OAuthError("invalid_client_metadata")
        if data.get("token_endpoint_auth_method", "none") != "none" or data.get("response_types", ["code"]) != ["code"] or data.get("scope", SCOPE) != SCOPE:
            raise OAuthError("invalid_client_metadata")
        client = random_value()
        with self.store.tx() as db:
            self.room(db, "oauth_clients", 1024)
            db.execute("INSERT INTO oauth_clients VALUES (?,?,?,1)", (client, json.dumps(redirects), time.time() + 600))
        return {"client_id": client, "redirect_uris": redirects, "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "scope": SCOPE}

    def client(self, db: sqlite3.Connection, client: str, redirect: str | None = None) -> None:
        row = db.execute("SELECT * FROM oauth_clients WHERE id=? AND expires>?", (client, time.time())).fetchone()
        if not row or (redirect is not None and redirect not in json.loads(row["redirects"])):
            raise OAuthError("invalid_client")

    def authorize(self, data: dict[str, str]) -> str:
        if set(data) - {"client_id", "redirect_uri", "response_type", "scope", "state", "resource", "code_challenge", "code_challenge_method"} or data.get("response_type") != "code" or data.get("scope") != SCOPE or data.get("resource") != self.resource or data.get("code_challenge_method") != "S256" or not re.fullmatch(r"[A-Za-z0-9_-]{43}", data.get("code_challenge", "")) or not data.get("state") or len(data["state"]) > 1024:
            raise OAuthError()
        with self.store.tx() as db:
            self.client(db, data.get("client_id", ""), data.get("redirect_uri", ""))
        payload = base64.urlsafe_b64encode(json.dumps({**data, "exp": time.time() + 600, "nonce": random_value()}, separators=(",", ":")).encode()).decode().rstrip("=")
        return payload + "." + hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()

    def session(self, value: str) -> dict:
        if not isinstance(value, str) or value.count(".") != 1 or len(value) > 8192:
            raise OAuthError("access_denied", 403)
        payload, signature = value.split(".")
        if not hmac.compare_digest(hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest(), signature):
            raise OAuthError("access_denied", 403)
        try:
            data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        except (ValueError, UnicodeError):
            raise OAuthError("access_denied", 403) from None
        if not isinstance(data, dict) or not isinstance(data.get("exp"), (int, float)) or data["exp"] <= time.time():
            raise OAuthError("access_denied", 403)
        return data

    def consent(self, session: str, csrf: str, enrollment: str) -> str:
        if not session or not hmac.compare_digest(session.encode(), csrf.encode()):
            raise OAuthError("access_denied", 403)
        data = {key: value for key, value in self.session(session).items() if key not in ("exp", "nonce")}
        failure = False
        with self.store.tx() as db:
            entry = db.execute("SELECT * FROM oauth_enrollment WHERE hash=? AND expires>?", (digest(enrollment), time.time())).fetchone()
            if not entry:
                failure = True
            else:
                row = self.endpoint(db, entry["endpoint"], entry["key_hash"])
                self.client(db, data["client_id"], data["redirect_uri"])
                data.update(endpoint=row["endpoint"], key_hash=row["key_hash"])
                self.room(db, "oauth_codes", 128)
                value = random_value()
                db.execute("INSERT INTO oauth_codes VALUES (?,?,?)", (digest(value), json.dumps(data), min(time.time() + 300, row["expires"])))
                db.execute("DELETE FROM oauth_enrollment WHERE hash=?", (entry["hash"],))
        if failure:
            raise OAuthError("access_denied", 403)
        return data["redirect_uri"] + "?" + urlencode({"code": value, "state": data["state"], "iss": self.origin})

    def mint(self, db: sqlite3.Connection, grant: sqlite3.Row) -> dict:
        endpoint = self.endpoint(db, grant["endpoint"], grant["key_hash"])
        if grant["revoked"] or grant["expires"] <= time.time() or grant["resource"] != self.resource:
            raise OAuthError("invalid_grant")
        self.room(db, "oauth_tokens", 8191)
        access, refresh = random_value(), random_value()
        now = time.time()
        expires = min(now + 3600, grant["expires"], endpoint["expires"])
        db.execute("INSERT INTO oauth_tokens VALUES (?,?, 'access',?,0)", (digest(access), grant["id"], expires))
        db.execute("INSERT INTO oauth_tokens VALUES (?,?, 'refresh',?,0)", (digest(refresh), grant["id"], grant["expires"]))
        return {"access_token": access, "refresh_token": refresh, "token_type": "Bearer", "expires_in": max(0, int(expires - now)), "scope": SCOPE}

    def token(self, data: dict[str, str]) -> dict:
        replay = False
        with self.store.tx() as db:
            self.client(db, data.get("client_id", ""))
            if data.get("resource") != self.resource or data.get("scope", SCOPE) != SCOPE:
                raise OAuthError("invalid_target")
            if data.get("grant_type") == "authorization_code":
                row = db.execute("SELECT * FROM oauth_codes WHERE hash=? AND expires>?", (digest(data.get("code", "")), time.time())).fetchone()
                if not row:
                    raise OAuthError("invalid_grant")
                value = json.loads(row["payload"])
                verifier = data.get("code_verifier", "")
                if value["client_id"] != data["client_id"] or value["redirect_uri"] != data.get("redirect_uri") or value["resource"] != data["resource"] or not re.fullmatch(r"[A-Za-z0-9._~-]{43,128}", verifier) or not hmac.compare_digest(challenge(verifier), value["code_challenge"]):
                    raise OAuthError("invalid_grant")
                endpoint = self.endpoint(db, value["endpoint"], value["key_hash"])
                db.execute("""DELETE FROM oauth_grants WHERE endpoint=? AND id NOT IN (
                    SELECT id FROM oauth_grants WHERE endpoint=? ORDER BY rowid DESC LIMIT 7)""", (value["endpoint"], value["endpoint"]))
                self.room(db, "oauth_grants", 128)
                if db.execute("SELECT provisional FROM oauth_clients WHERE id=?", (data["client_id"],)).fetchone()[0]:
                    if db.execute("SELECT count(*) FROM oauth_clients WHERE provisional=0").fetchone()[0] >= 128:
                        raise OAuthError("temporarily_unavailable", 429)
                grant_id = random_value()
                db.execute("INSERT INTO oauth_grants VALUES (?,?,?,?,?,?,0)", (grant_id, data["client_id"], value["endpoint"], value["key_hash"], self.resource, min(time.time() + 30 * 86400, endpoint["expires"])))
                grant = db.execute("SELECT * FROM oauth_grants WHERE id=?", (grant_id,)).fetchone()
                result = self.mint(db, grant)
                db.execute("UPDATE oauth_clients SET expires=?, provisional=0 WHERE id=?", (time.time() + 90 * 86400, data["client_id"]))
                db.execute("DELETE FROM oauth_codes WHERE hash=?", (row["hash"],))
            elif data.get("grant_type") == "refresh_token":
                token = db.execute("SELECT * FROM oauth_tokens WHERE hash=? AND kind='refresh' AND expires>?", (digest(data.get("refresh_token", "")), time.time())).fetchone()
                grant = db.execute("SELECT * FROM oauth_grants WHERE id=? AND client=?", (token["grant_id"], data["client_id"])).fetchone() if token else None
                if not grant:
                    raise OAuthError("invalid_grant")
                if token["used"] or db.execute("SELECT count(*) FROM oauth_tokens WHERE grant_id=? AND kind='refresh' AND used=1", (grant["id"],)).fetchone()[0] >= 2048:
                    db.execute("UPDATE oauth_grants SET revoked=1 WHERE id=?", (grant["id"],))
                    replay = True
                else:
                    result = self.mint(db, grant)
                    db.execute("UPDATE oauth_tokens SET used=1 WHERE hash=?", (token["hash"],))
            else:
                raise OAuthError("unsupported_grant_type")
        if replay:
            raise OAuthError("invalid_grant")
        return result

    def revoke(self, data: dict[str, str]) -> None:
        with self.store.tx() as db:
            self.client(db, data.get("client_id", ""))
            db.execute("UPDATE oauth_grants SET revoked=1 WHERE client=? AND id IN (SELECT grant_id FROM oauth_tokens WHERE hash=?)", (data["client_id"], digest(data.get("token", ""))))

    def principal(self, authorization: str) -> str:
        if not authorization.startswith("Bearer ") or len(authorization) > 1024:
            raise OAuthError("invalid_token", 401)
        with self.store.tx() as db:
            row = db.execute("SELECT g.* FROM oauth_tokens t JOIN oauth_grants g ON g.id=t.grant_id WHERE t.hash=? AND t.kind='access' AND t.expires>? AND g.expires>? AND g.revoked=0 AND g.resource=?", (digest(authorization[7:]), time.time(), time.time(), self.resource)).fetchone()
            if not row:
                raise OAuthError("invalid_token", 401)
            try:
                self.client(db, row["client"])
                endpoint = self.endpoint(db, row["endpoint"], row["key_hash"])
            except OAuthError as error:
                raise OAuthError("invalid_token", 401) from error
            return endpoint["principal"]


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    async with gateway_lifespan(app):
        origin = os.environ.get("HOUSEHOLD_PUBLIC_ORIGIN", "")
        gateway = app.state.household_gateway
        app.state.household_oauth = OAuth(gateway.store, origin) if origin and gateway else None
        try:
            yield
        finally:
            app.state.household_oauth = None


def configured(request: Request) -> OAuth:
    oauth = getattr(request.app.state, "household_oauth", None)
    if oauth is None:
        raise HTTPException(404, "Not found")
    return oauth


async def body(request: Request, json_body: bool = False, limit: int = 8192) -> dict:
    expected = "application/json" if json_body else "application/x-www-form-urlencoded"
    if request.headers.get("content-type", "").split(";")[0] != expected:
        raise OAuthError()
    value = bytearray()
    async for chunk in request.stream():
        value.extend(chunk)
        if len(value) > limit:
            raise OAuthError("invalid_request", 413)
    try:
        if json_body:
            result = json.loads(value)
            if not isinstance(result, dict):
                raise ValueError()
            return result
        pairs = parse_qsl(value.decode(), keep_blank_values=True, strict_parsing=True, max_num_fields=20)
        if len(dict(pairs)) != len(pairs):
            raise ValueError()
        return dict(pairs)
    except (ValueError, UnicodeError) as error:
        raise OAuthError() from error


def error_response(error: OAuthError) -> JSONResponse:
    return JSONResponse({"error": error.code}, status_code=error.status, headers=HEADERS)


@router.get("/.well-known/oauth-protected-resource")
@router.get("/.well-known/oauth-protected-resource/mcp")
async def resource_metadata(request: Request) -> JSONResponse:
    oauth = configured(request)
    return JSONResponse({"resource": oauth.resource, "authorization_servers": [oauth.origin], "scopes_supported": [SCOPE], "bearer_methods_supported": ["header"]}, headers=HEADERS)


@router.get("/.well-known/oauth-authorization-server")
async def authorization_metadata(request: Request) -> JSONResponse:
    oauth = configured(request)
    return JSONResponse({"issuer": oauth.origin, "authorization_endpoint": oauth.origin + "/oauth/authorize", "token_endpoint": oauth.origin + "/oauth/token", "registration_endpoint": oauth.origin + "/oauth/register", "revocation_endpoint": oauth.origin + "/oauth/revoke", "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"], "token_endpoint_auth_methods_supported": ["none"], "revocation_endpoint_auth_methods_supported": ["none"], "code_challenge_methods_supported": ["S256"], "scopes_supported": [SCOPE], "authorization_response_iss_parameter_supported": True}, headers=HEADERS)


@router.post("/oauth/register")
@router.post("/oauth/token")
@router.post("/oauth/revoke")
async def exchange(request: Request) -> JSONResponse:
    oauth = configured(request)
    route = request.url.path.rsplit("/", 1)[-1]
    try:
        data = await body(request, route == "register")
        if route == "register":
            oauth.rate(route, 20)
        else:
            oauth.rate(route, 120, await run_in_threadpool(oauth.secret_key, data))
        if request.headers.get("authorization") or "client_secret" in data or "client_assertion" in data:
            raise OAuthError("invalid_client")
        result = await run_in_threadpool(getattr(oauth, route), data)
        return JSONResponse(result or {}, status_code=201 if route == "register" else 200, headers=HEADERS)
    except OAuthError as error:
        return error_response(error)


@router.get("/oauth/authorize")
async def authorize(request: Request) -> Response:
    oauth = configured(request)
    try:
        if len(request.url.query) > 4096 or len(request.query_params.multi_items()) != len(request.query_params):
            raise OAuthError()
        session = await run_in_threadpool(oauth.authorize, dict(request.query_params))
        page = Template('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Connect your inbox</title><main><h1>Connect your inbox</h1><p>Enter your one-time inbox code. Connecting lets ChatGPT read your inbox, receive notifications, and share messages only when you ask. Your other conversations stay separate.</p><form method="post" action="/oauth/authorize"><input type="hidden" name="csrf" value="$csrf"><label>Inbox code <input name="enrollment" type="password" required maxlength="128" autocomplete="off"></label><button type="submit" name="action" value="connect">Connect</button></form><p>Close this window to cancel.</p></main></html>').substitute(csrf=html.escape(session, quote=True))
        response = HTMLResponse(page, headers=HEADERS)
        response.set_cookie(COOKIE, session, max_age=600, secure=True, httponly=True, samesite="lax", path="/")
        return response
    except OAuthError as error:
        return error_response(error)


@router.post("/oauth/authorize")
async def consent(request: Request) -> Response:
    oauth = configured(request)
    try:
        oauth.rate("consent", 30)
        if request.headers.get("origin") != oauth.origin:
            raise OAuthError("access_denied", 403)
        data = await body(request)
        if set(data) != {"csrf", "enrollment", "action"} or data["action"] != "connect":
            raise OAuthError()
        target = await run_in_threadpool(oauth.consent, request.cookies.get(COOKIE, ""), data["csrf"], data["enrollment"])
        response = RedirectResponse(target, status_code=303, headers=HEADERS)
        response.delete_cookie(COOKIE, secure=True, httponly=True, samesite="lax", path="/")
        return response
    except OAuthError as error:
        return error_response(error)


@router.post("/mcp")
@router.get("/mcp")
async def public_mcp(request: Request) -> Response:
    oauth = configured(request)
    try:
        oauth.rate("mcp", 600, await run_in_threadpool(oauth.bearer_key, request.headers.get("authorization", "")))
        actor = await run_in_threadpool(oauth.principal, request.headers.get("authorization", ""))
    except OAuthError as error:
        headers = HEADERS | {"WWW-Authenticate": 'Bearer resource_metadata="' + oauth.origin + '/.well-known/oauth-protected-resource/mcp", scope="' + SCOPE + '"'}
        return JSONResponse({"error": error.code}, status_code=error.status, headers=headers)
    if request.method == "GET":
        return Response(status_code=405, headers=HEADERS | {"Allow": "POST"})
    rpc_id = None
    try:
        rpc = await body(request, True, 32768)
        if rpc.get("jsonrpc") != "2.0" or not isinstance(rpc.get("method"), str) or not isinstance(rpc.get("params", {}), dict):
            raise ValueError()
        if "id" not in rpc and rpc["method"] in ("notifications/initialized", "notifications/cancelled"):
            return Response(status_code=202, headers=HEADERS)
        if type(rpc.get("id")) not in (str, int):
            raise ValueError()
        rpc_id = rpc["id"]
        gateway: Gateway = request.app.state.household_gateway
        if rpc["method"] == "initialize":
            params = rpc.get("params", {})
            if not isinstance(params.get("protocolVersion"), str) or not isinstance(params.get("capabilities", {}), dict) or not isinstance(params.get("clientInfo", {}), dict):
                raise ValueError()
            supported = ("2024-11-05", "2025-03-26", "2025-06-18", "2026-07-28")
            version = params["protocolVersion"] if params["protocolVersion"] in supported else supported[-1]
            result = {"protocolVersion": version, "capabilities": {"tools": {}} | ({"events": {}} if gateway.event_discovery else {}), "serverInfo": {"name": "household", "version": "0.1.0"}}
        elif rpc["method"] == "ping":
            result = {}
        else:
            result = await run_in_threadpool(gateway.dispatch, actor, rpc["method"], rpc.get("params", {}))
        return JSONResponse({"jsonrpc": "2.0", "id": rpc_id, "result": result}, headers=HEADERS)
    except OAuthError as error:
        return error_response(error)
    except CallbackError:
        code, message = -32015, "Callback verification failed"
    except Denied:
        code, message = -32001, "Access denied"
    except LookupError:
        code, message = -32601, "Unknown method or missing field"
    except (ValueError, TypeError, ValidationError):
        code, message = -32602, "Invalid request"
    return JSONResponse({"jsonrpc": "2.0", "id": rpc_id, "error": {"code": code, "message": message}}, headers=HEADERS)
