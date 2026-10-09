import base64
import hashlib
import hmac
import http.client
import ipaddress
import json
import secrets
import socket
import ssl
import time
import threading
from concurrent.futures import ThreadPoolExecutor
import uuid
from datetime import datetime, timezone
from typing import Callable
from urllib.parse import urlsplit

from .household_store import Denied, Store, canonical

EVENT = "household.message.created"
_RESOLVER = ThreadPoolExecutor(max_workers=2)
_RESOLVER_SLOTS = threading.BoundedSemaphore(2)
class CallbackError(ValueError):
    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


Transport = Callable[[str, bytes, dict[str, str]], tuple[int, bytes]]


def timestamp(seconds: float) -> str:
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat()


def signing_key(secret: str) -> bytes:
    try:
        key = base64.b64decode(secret.removeprefix("whsec_"), validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("Invalid signing secret") from error
    if not secret.startswith("whsec_") or not 24 <= len(key) <= 64:
        raise ValueError("Invalid signing secret")
    return key


def headers(event_id: str, sub_id: str, body: bytes, secret: str, old: str | None = None) -> dict[str, str]:
    signed_at = str(int(time.time()))
    payload = event_id.encode() + b"." + signed_at.encode() + b"." + body
    signatures = ["v1," + base64.b64encode(hmac.digest(signing_key(key), payload, "sha256")).decode() for key in [secret, old] if key]
    return {"Content-Type": "application/json", "webhook-id": event_id,
            "webhook-timestamp": signed_at, "webhook-signature": " ".join(signatures),
            "X-MCP-Subscription-Id": sub_id}


class PublicHTTPS:
    def __init__(self, approved_hosts: set[str]):
        self.approved_hosts = approved_hosts

    def __call__(self, url: str, body: bytes, request_headers: dict[str, str]) -> tuple[int, bytes]:
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname not in self.approved_hosts or parsed.username or parsed.password or parsed.fragment or parsed.port not in (None, 443):
            raise ValueError("Callback destination not approved")
        if not _RESOLVER_SLOTS.acquire(blocking=False):
            raise TimeoutError("Callback resolver busy")
        lookup = _RESOLVER.submit(socket.getaddrinfo, parsed.hostname, 443, 0, socket.SOCK_STREAM)
        lookup.add_done_callback(lambda _: _RESOLVER_SLOTS.release())
        addresses = lookup.result(timeout=5)
        if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
            raise ValueError("Callback requires public addresses")
        family, socktype, proto, _, address = addresses[0]
        connection = http.client.HTTPSConnection(parsed.hostname, 443, timeout=5)
        raw = socket.socket(family, socktype, proto)
        raw.settimeout(5)
        def close_connection() -> None:
            target = connection.sock or raw
            try:
                target.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            target.close()
        timer = threading.Timer(10, close_connection)
        timer.daemon = True
        timer.start()
        try:
            raw.connect(address)
            connection.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=parsed.hostname)
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
            connection.request("POST", path, body, request_headers)
            response = connection.getresponse()
            return response.status, response.read(4097)
        finally:
            timer.cancel()
            connection.close()
            raw.close()


class Events:
    def __init__(self, store: Store, transport: Transport):
        self.store = store
        self.transport = transport

    def identity(self, actor: str, name: str, arguments: dict, delivery: dict) -> str:
        if name != EVENT or arguments != {} or delivery.get("mode") != "webhook":
            raise ValueError("Invalid event subscription")
        url = delivery.get("url", "")
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.port not in (None, 443) or len(url) > 2048:
            raise ValueError("Invalid callback URL")
        return hashlib.sha256(canonical([actor, name, arguments, url]).encode()).hexdigest()

    def subscribe(self, actor: str, name: str, arguments: dict, delivery: dict, ttl_ms: int | None = 3600000) -> dict:
        sub_id = self.identity(actor, name, arguments, delivery)
        secret = delivery.get("secret", "")
        signing_key(secret)
        if ttl_ms is not None and (type(ttl_ms) is not int or ttl_ms <= 0):
            raise ValueError("Invalid subscription lifetime")
        ttl = min(ttl_ms / 1000, 86400) if ttl_ms is not None else 3600
        with self.store.tx() as db:
            self.store.require(db, actor)
            if db.execute("SELECT count(*) FROM subscriptions WHERE owner=? AND active=1 AND expires>? AND id!=?", (actor, time.time(), sub_id)).fetchone()[0] >= 8:
                raise Denied("Subscription limit reached")
            epoch = db.execute("SELECT generation FROM subscription_epochs WHERE id=?", (sub_id,)).fetchone()
            generation = epoch[0] if epoch else 0
        challenge = secrets.token_urlsafe(32)
        body = canonical({"type": "verification", "challenge": challenge}).encode()
        try:
            code, reply = self.transport(delivery["url"], body, headers(str(uuid.uuid4()), sub_id, body, secret))
        except TimeoutError as error:
            raise CallbackError("timeout") from error
        except (OSError, ValueError, http.client.HTTPException) as error:
            raise CallbackError("connection_failed") from error
        try:
            returned = json.loads(reply).get("challenge", "")
        except (ValueError, AttributeError):
            returned = ""
        if not 200 <= code < 300 or not isinstance(returned, str) or not hmac.compare_digest(returned.encode(), challenge.encode()):
            raise CallbackError("challenge_failed")
        with self.store.tx() as db:
            self.store.require(db, actor)
            if db.execute("SELECT count(*) FROM subscriptions WHERE owner=? AND active=1 AND expires>? AND id!=?", (actor, time.time(), sub_id)).fetchone()[0] >= 8:
                raise Denied("Subscription limit reached")
            epoch = db.execute("SELECT generation FROM subscription_epochs WHERE id=?", (sub_id,)).fetchone()
            if (epoch[0] if epoch else 0) != generation:
                raise Denied("Subscription was revoked during verification")
            now = time.time()
            old = db.execute("SELECT secret FROM subscriptions WHERE id=? AND active=1", (sub_id,)).fetchone()
            previous = old[0] if old and old[0] != secret else None
            if old and old[0] == secret:
                db.execute("UPDATE subscriptions SET expires=? WHERE id=?", (now + ttl, sub_id))
            else:
                db.execute("INSERT INTO subscriptions VALUES (?,?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET secret=excluded.secret, old_secret=excluded.old_secret, rotate_until=excluded.rotate_until, expires=excluded.expires, active=1", (sub_id, actor, delivery["url"], secret, previous, now + 300 if previous else 0, now + ttl))
            return {"id": sub_id, "refreshBefore": timestamp(now + ttl), "cursor": None, "truncated": False}

    def unsubscribe(self, actor: str, name: str, arguments: dict, delivery: dict) -> dict:
        sub_id = self.identity(actor, name, arguments, delivery)
        with self.store.tx() as db:
            self.store.require(db, actor)
            db.execute("INSERT INTO subscription_epochs VALUES (?,1) ON CONFLICT(id) DO UPDATE SET generation=generation+1", (sub_id,))
            db.execute("UPDATE subscriptions SET active=0,secret='',old_secret=NULL WHERE id=? AND owner=?", (sub_id, actor))
            db.execute("UPDATE outbox SET state='canceled' WHERE subscription_id=? AND state='pending'", (sub_id,))
        return {}

    def tick(self, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        with self.store.tx() as db:
            item = db.execute("SELECT * FROM outbox WHERE state='pending' AND next_at<=? ORDER BY next_at,event_id LIMIT 1", (now,)).fetchone()
            if not item:
                return False
            if item["attempts"] >= 5:
                db.execute("UPDATE outbox SET state='failed' WHERE event_id=?", (item["event_id"],))
                return True
            db.execute("UPDATE outbox SET attempts=attempts+1,next_at=? WHERE event_id=?", (now + 30, item["event_id"]))
        with self.store.tx() as db:
            current = db.execute("SELECT state FROM outbox WHERE event_id=?", (item["event_id"],)).fetchone()
            sub = db.execute("SELECT * FROM subscriptions WHERE id=?", (item["subscription_id"],)).fetchone()
            message = db.execute("SELECT * FROM messages WHERE id=?", (item["message_id"],)).fetchone()
            try:
                if current[0] != "pending" or not sub or not sub["active"] or sub["expires"] <= now or not message:
                    raise Denied("Delivery inactive")
                self.store.allowed(db, message)
                self.store.require(db, sub["owner"])
                if sub["owner"] != message["recipient"]:
                    raise Denied("Wrong inbox")
            except Denied:
                db.execute("UPDATE outbox SET state='canceled' WHERE event_id=?", (item["event_id"],))
                return True
            body = canonical({"eventId": item["event_id"], "name": EVENT,
                              "timestamp": timestamp(message["created"]),
                              "data": {"message_id": message["id"]}, "cursor": None}).encode()
            old = sub["old_secret"] if sub["rotate_until"] > now else None
        try:
            code, _ = self.transport(sub["url"], body, headers(item["event_id"], sub["id"], body, sub["secret"], old))
        except (OSError, ValueError, http.client.HTTPException):
            code = 503
        with self.store.tx() as db:
            current = db.execute("SELECT state FROM outbox WHERE event_id=?", (item["event_id"],)).fetchone()
            if current[0] != "pending":
                return True
            attempts = item["attempts"] + 1
            accepted = 200 <= code < 300
            retry = (code in (408, 429) or 500 <= code <= 599) and attempts < 5
            state = "received" if accepted else "pending" if retry else "failed"
            db.execute("UPDATE outbox SET state=?,next_at=?,receipt=? WHERE event_id=?", (state, now + 30 * (2 ** (attempts - 1)), now if accepted else None, item["event_id"]))
            if code == 410:
                db.execute("UPDATE subscriptions SET active=0,secret='',old_secret=NULL WHERE id=?", (sub["id"],))
        return True
