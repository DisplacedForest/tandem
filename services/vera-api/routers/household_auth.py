import hashlib
import hmac
import re
import time

from .household_gateway_store import Denied, Store


class EndpointKeys:
    def __init__(self, store: Store):
        self.store = store

    def provision(self, endpoint: str, key: str, lifetime: int = 2592000) -> None:
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,63}", endpoint):
            raise ValueError("Endpoint must be a lowercase identifier of 3 to 64 characters")
        if not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", key) or not 3600 <= lifetime <= 31536000:
            raise ValueError("Use a random key of at least 32 bytes and a bounded lifetime")
        with self.store.tx() as db:
            db.execute("INSERT INTO members VALUES (?,1)", (endpoint,))
            db.execute("INSERT INTO inbox_endpoints VALUES (?,?,?,?,1)", (endpoint, endpoint, hashlib.sha256(key.encode()).hexdigest(), time.time() + lifetime))

    def verify(self, endpoint: str, key: str) -> str | None:
        digest = hashlib.sha256(key.encode()).hexdigest()
        with self.store.tx() as db:
            row = db.execute("SELECT e.* FROM inbox_endpoints e JOIN members m ON m.id=e.principal WHERE e.endpoint=? AND e.enabled=1 AND m.enabled=1 AND e.expires>?", (endpoint, time.time())).fetchone()
            expected = row["key_hash"] if row else "0" * 64
            valid = hmac.compare_digest(expected, digest)
            return row["principal"] if row and valid else None

    def rotate(self, endpoint: str, key: str, lifetime: int = 2592000) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", key) or not 3600 <= lifetime <= 31536000:
            raise ValueError("Invalid key or lifetime")
        with self.store.tx() as db:
            row = db.execute("SELECT e.principal FROM inbox_endpoints e JOIN members m ON m.id=e.principal WHERE e.endpoint=? AND e.enabled=1 AND m.enabled=1", (endpoint,)).fetchone()
            if not row:
                raise Denied("Endpoint is not active")
            db.execute("UPDATE inbox_endpoints SET key_hash=?,expires=? WHERE endpoint=?", (hashlib.sha256(key.encode()).hexdigest(), time.time() + lifetime, endpoint))

    def revoke(self, endpoint: str) -> None:
        with self.store.tx() as db:
            row = db.execute("SELECT principal FROM inbox_endpoints WHERE endpoint=?", (endpoint,)).fetchone()
            if not row:
                return
            principal = row[0]
            db.execute("UPDATE inbox_endpoints SET enabled=0,key_hash='' WHERE endpoint=?", (endpoint,))
            db.execute("UPDATE members SET enabled=0 WHERE id=?", (principal,))
            db.execute("UPDATE pairs SET state='revoked' WHERE sender=? OR recipient=?", (principal, principal))
            db.execute("UPDATE subscriptions SET active=0,secret='',old_secret=NULL WHERE owner=?", (principal,))
            db.execute("UPDATE outbox SET state='canceled' WHERE state='pending' AND message_id IN (SELECT id FROM messages WHERE sender=? OR recipient=?)", (principal, principal))

    def list(self) -> list[dict]:
        with self.store.tx() as db:
            return [dict(row) for row in db.execute("SELECT endpoint,expires,enabled FROM inbox_endpoints ORDER BY endpoint")]
