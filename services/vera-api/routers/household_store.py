import hashlib
import json
import os
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


class Denied(ValueError):
    pass


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class Store:
    def __init__(self, path: str):
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        os.close(fd)
        with self.tx() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS inbox_endpoints(endpoint TEXT PRIMARY KEY, principal TEXT UNIQUE NOT NULL, key_hash TEXT NOT NULL, expires REAL NOT NULL, enabled INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS members(id TEXT PRIMARY KEY, enabled INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS pairs(id TEXT PRIMARY KEY, sender TEXT NOT NULL,
                    recipient TEXT NOT NULL, scopes TEXT NOT NULL, state TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, pair_id TEXT NOT NULL,
                    sender TEXT NOT NULL, recipient TEXT NOT NULL, kind TEXT NOT NULL,
                    body TEXT NOT NULL, dedup TEXT NOT NULL, fingerprint TEXT NOT NULL,
                    parent TEXT, depth INTEGER NOT NULL, created REAL NOT NULL,
                    delivered REAL, processed REAL, UNIQUE(sender,dedup));
                CREATE UNIQUE INDEX IF NOT EXISTS reply_once ON messages(sender,parent)
                    WHERE parent IS NOT NULL;
                CREATE TABLE IF NOT EXISTS subscriptions(id TEXT PRIMARY KEY, owner TEXT NOT NULL,
                    url TEXT NOT NULL, secret TEXT NOT NULL, old_secret TEXT,
                    rotate_until REAL NOT NULL DEFAULT 0, expires REAL NOT NULL,
                    active INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS subscription_epochs(id TEXT PRIMARY KEY, generation INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS outbox(event_id TEXT PRIMARY KEY,
                    message_id TEXT NOT NULL, subscription_id TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending', receipt REAL,
                    UNIQUE(message_id,subscription_id));
            """)

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA foreign_keys=ON")
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def enroll(self, principal: str) -> None:
        if not principal or len(principal) > 200:
            raise ValueError("Invalid principal")
        with self.tx() as db:
            db.execute("INSERT INTO members VALUES (?,1)", (principal,))

    def require(self, db: sqlite3.Connection, principal: str) -> None:
        row = db.execute("SELECT enabled FROM members WHERE id=?", (principal,)).fetchone()
        if not row or not row[0]:
            raise Denied("Member access denied")
        endpoint = db.execute("SELECT enabled,expires FROM inbox_endpoints WHERE principal=?", (principal,)).fetchone()
        if endpoint and (not endpoint[0] or endpoint[1] <= time.time()):
            raise Denied("Endpoint access expired or revoked")

    def disable(self, principal: str) -> None:
        with self.tx() as db:
            db.execute("UPDATE members SET enabled=0 WHERE id=?", (principal,))
            db.execute("UPDATE pairs SET state='revoked' WHERE sender=? OR recipient=?", (principal, principal))
            db.execute("UPDATE subscriptions SET active=0, secret='', old_secret=NULL WHERE owner=?", (principal,))

    def pair(self, actor: str, peer: str, scopes: list[str]) -> str:
        if actor == peer or not scopes or len(scopes) != len(set(scopes)) or set(scopes) - {"message", "summary"}:
            raise ValueError("Choose a peer and explicit message or summary scopes")
        with self.tx() as db:
            self.require(db, actor)
            self.require(db, peer)
            if db.execute("SELECT count(*) FROM pairs WHERE sender=? AND state!='revoked'", (actor,)).fetchone()[0] >= 30:
                raise Denied("Pair limit reached")
            pair_id = str(uuid.uuid4())
            db.execute("INSERT INTO pairs VALUES (?,?,?,?,'pending')", (pair_id, actor, peer, canonical(sorted(scopes))))
            return pair_id

    def consent(self, actor: str, pair_id: str, accept: bool) -> None:
        with self.tx() as db:
            self.require(db, actor)
            row = db.execute("SELECT * FROM pairs WHERE id=?", (pair_id,)).fetchone()
            if not row or actor not in (row["sender"], row["recipient"]):
                raise Denied("Pair access denied")
            if accept and (actor != row["recipient"] or row["state"] not in ("pending", "active")):
                raise Denied("Only the invited member may accept a pending pair")
            if accept:
                self.require(db, row["sender"])
                self.require(db, row["recipient"])
            db.execute("UPDATE pairs SET state=? WHERE id=?", ("active" if accept else "revoked", pair_id))
            if not accept:
                db.execute("UPDATE outbox SET state='canceled' WHERE message_id IN (SELECT id FROM messages WHERE pair_id=?) AND state='pending'", (pair_id,))

    def pairs(self, actor: str) -> list[dict]:
        with self.tx() as db:
            self.require(db, actor)
            return [dict(r) | {"scopes": json.loads(r["scopes"])} for r in db.execute("SELECT * FROM pairs WHERE sender=? OR recipient=? ORDER BY rowid DESC LIMIT 100", (actor, actor))]

    def allowed(self, db: sqlite3.Connection, row: sqlite3.Row) -> None:
        self.require(db, row["sender"])
        self.require(db, row["recipient"])
        pair = db.execute("SELECT state FROM pairs WHERE id=?", (row["pair_id"],)).fetchone()
        if not pair or pair[0] != "active":
            raise Denied("Pair revoked")

    def send(self, actor: str, pair_id: str, kind: str, body: str, dedup: str, parent: str | None = None) -> str:
        if kind not in ("message", "summary") or not body.strip() or len(body.encode()) > 16384 or not dedup or len(dedup) > 128:
            raise ValueError("Invalid message, scope, or idempotency key")
        fingerprint = hashlib.sha256(canonical([pair_id, kind, body, parent]).encode()).hexdigest()
        with self.tx() as db:
            self.require(db, actor)
            pair = db.execute("SELECT * FROM pairs WHERE id=?", (pair_id,)).fetchone()
            if not pair or pair["state"] != "active" or actor not in (pair["sender"], pair["recipient"]) or kind not in json.loads(pair["scopes"]):
                raise Denied("Active bilateral consent for this scope is required")
            peer = pair["recipient"] if actor == pair["sender"] else pair["sender"]
            self.require(db, peer)
            old = db.execute("SELECT id,fingerprint FROM messages WHERE sender=? AND dedup=?", (actor, dedup)).fetchone()
            if old:
                if old["fingerprint"] != fingerprint:
                    raise ValueError("Idempotency key conflicts with an earlier message")
                return old["id"]
            depth = 0
            if parent is not None:
                previous = db.execute("SELECT * FROM messages WHERE id=?", (parent,)).fetchone()
                if not previous or previous["recipient"] != actor or previous["pair_id"] != pair_id or previous["depth"] >= 4:
                    raise Denied("Reply is not permitted")
                if db.execute("SELECT 1 FROM messages WHERE sender=? AND parent=?", (actor, parent)).fetchone():
                    raise Denied("A reply already exists")
                depth = previous["depth"] + 1
            now = time.time()
            if db.execute("SELECT count(*) FROM messages WHERE sender=? AND created>?", (actor, now - 3600)).fetchone()[0] >= 60:
                raise Denied("Hourly sharing limit reached")
            message_id = str(uuid.uuid4())
            db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?,?,?,?,?,?,NULL,NULL)", (message_id, pair_id, actor, peer, kind, body, dedup, fingerprint, parent, depth, now))
            for sub in db.execute("SELECT id FROM subscriptions WHERE owner=? AND active=1 AND expires>?", (peer, now)):
                db.execute("INSERT INTO outbox(event_id,message_id,subscription_id,next_at) VALUES (?,?,?,?)", (str(uuid.uuid4()), message_id, sub[0], now))
            return message_id

    def inbox(self, actor: str, after: int = 0) -> list[dict]:
        with self.tx() as db:
            self.require(db, actor)
            rows = db.execute("SELECT m.rowid AS cursor,m.* FROM messages m JOIN pairs p ON p.id=m.pair_id JOIN members s ON s.id=m.sender LEFT JOIN inbox_endpoints e ON e.principal=m.sender WHERE m.recipient=? AND p.state='active' AND s.enabled=1 AND m.rowid>? AND (e.principal IS NULL OR (e.enabled=1 AND e.expires>?)) ORDER BY m.rowid LIMIT 100", (actor, after, time.time()))
            return [self.public(row) for row in rows]

    def public(self, row: sqlite3.Row) -> dict:
        return {k: row[k] for k in ("id", "pair_id", "cursor", "sender", "recipient", "kind", "body", "parent", "created", "delivered", "processed")} | {"trust": "third_party_data", "grants_tool_authority": False}

    def acknowledge(self, actor: str, message_id: str, stage: str) -> None:
        if stage not in ("delivered", "processed"):
            raise ValueError("Unknown acknowledgment stage")
        with self.tx() as db:
            self.require(db, actor)
            row = db.execute("SELECT * FROM messages WHERE id=? AND recipient=?", (message_id, actor)).fetchone()
            if not row:
                raise Denied("Message access denied")
            self.allowed(db, row)
            if stage == "processed" and row["delivered"] is None:
                raise ValueError("Delivery must be acknowledged first")
            query = {
                "delivered": "UPDATE messages SET delivered=COALESCE(delivered,?) WHERE id=?",
                "processed": "UPDATE messages SET processed=COALESCE(processed,?) WHERE id=?",
            }[stage]
            db.execute(query, (time.time(), message_id))

    def status(self, actor: str, message_id: str) -> dict:
        with self.tx() as db:
            self.require(db, actor)
            row = db.execute("SELECT * FROM messages WHERE id=? AND (sender=? OR recipient=?)", (message_id, actor, actor)).fetchone()
            if not row:
                raise Denied("Message access denied")
            self.allowed(db, row)
            receipts = db.execute("SELECT count(*) FROM outbox WHERE message_id=? AND receipt IS NOT NULL", (message_id,)).fetchone()[0]
            return {"id": message_id, "webhook_receipts": receipts, "delivered": row["delivered"], "processed": row["processed"]}
