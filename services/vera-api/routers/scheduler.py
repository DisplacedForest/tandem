"""Built-in scheduler — vera-api runs its own recurring jobs; no n8n, no host cron.

Every job that is a pure internal call (the same handler its HTTP endpoint uses) runs
from one asyncio loop here. Host-level work that genuinely needs the host (filesystem
backups, bringing up a local model server) stays outside — everything else is this.

  GET  /scheduler/jobs           -> the job table (cron, enabled, last/next run)
  PUT  /scheduler/jobs/{id}      -> change cron and/or enabled (persisted)
  POST /scheduler/jobs/{id}/run  -> fire a job now (manual)

Config precedence per job: env (SCHEDULE_<ID>, SCHEDULE_<ID>_ENABLED — headless installs)
beats the db row (runtime edits from the Agentic tab) beats the registry default. A job
whose env says disabled is LOCKED: the API refuses to enable it (double-fire guard while
an external scheduler still owns it). SCHEDULER_ENABLED=false kills the loop entirely.

Cron expressions are evaluated in HOME_TZ. Failures never stop the loop; each job records
its last outcome for the UI. A job still running when its next fire comes due is skipped
(no overlapping instances).
"""

import asyncio
import logging
import os
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from croniter import croniter
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from . import scheduler_store as store

router = APIRouter()
log = logging.getLogger("vera.scheduler")

ENABLED = os.environ.get("SCHEDULER_ENABLED", "true").strip().lower() != "false"
TZ = ZoneInfo(os.environ.get("HOME_TZ", "UTC"))
_POLL_SECONDS = 20


REGISTRY: dict[str, tuple[str, str, object]] = {}
GATES: dict[str, object] = {}
_JOB_ORDER: dict[str, int] = {}
_JOB_OWNERS: dict[str, str] = {}


def register_job(job_id: str, label: str, cron: str, handler: Callable[[], Awaitable[Any]], *,
                 order: int, gate: Callable[[], str | None] | None = None) -> None:
    owner = getattr(handler, "__module__", "") or ""
    if job_id in _JOB_ORDER and _JOB_OWNERS.get(job_id) != owner:
        raise ValueError(f"scheduler job already registered: {job_id}")
    GATES.pop(job_id, None)
    _JOB_OWNERS[job_id] = owner
    REGISTRY[job_id] = (label, cron, handler)
    _JOB_ORDER[job_id] = order
    if gate is not None:
        GATES[job_id] = gate
    ordered = {j: REGISTRY[j] for j in sorted(_JOB_ORDER, key=lambda j: _JOB_ORDER[j]) if j in REGISTRY}
    extras = {j: v for j, v in REGISTRY.items() if j not in _JOB_ORDER}
    REGISTRY.clear()
    REGISTRY.update(ordered)
    REGISTRY.update(extras)
    gates = {j: GATES[j] for j in ordered if j in GATES}
    gates.update({j: g for j, g in GATES.items() if j not in gates})
    GATES.clear()
    GATES.update(gates)


def unregister_job(job_id: str) -> None:
    REGISTRY.pop(job_id, None)
    GATES.pop(job_id, None)
    _JOB_ORDER.pop(job_id, None)
    _JOB_OWNERS.pop(job_id, None)


def _vein_gate(kind: str):
    """Gate factory: a vein's producer jobs run only while the vein is enabled (and its
    requirements hold) — no orphaned producers burning tokens for a hidden chip."""
    def gate() -> str | None:
        from . import pulse_veins
        return pulse_veins.gate_reason(kind)
    return gate


def builtin_jobs() -> dict[str, tuple[str, str, object]]:
    from . import builtin_capabilities
    builtin_capabilities.load()
    return REGISTRY


def _registry() -> dict[str, tuple[str, str, object]]:
    from . import vein_engine
    return {**builtin_jobs(), **vein_engine.dynamic_jobs()}


# ---- effective config (env > db > registry) ------------------------------------------

def _env_cron(job_id: str) -> str | None:
    v = os.environ.get(f"SCHEDULE_{job_id.upper()}", "").strip()
    return v or None


def _env_enabled(job_id: str) -> bool | None:
    v = os.environ.get(f"SCHEDULE_{job_id.upper()}_ENABLED", "").strip().lower()
    if v in ("true", "1", "yes", "on"):
        return True
    if v in ("false", "0", "no", "off"):
        return False
    return None


def _gate_reason(job_id: str) -> str | None:
    builtin_jobs()
    gate = GATES.get(job_id)
    if gate is None and job_id.startswith("vein_"):
        gate = _vein_gate(job_id.removeprefix("vein_"))
    return gate() if gate else None


def _effective(job_id: str, row: dict | None, reg: dict | None = None) -> dict:
    label, default_cron, _ = (reg or _registry())[job_id]
    env_cron, env_enabled = _env_cron(job_id), _env_enabled(job_id)
    cron = env_cron or (row or {}).get("cron") or default_cron
    if env_enabled is not None:
        enabled = env_enabled
    elif row is not None and row.get("enabled") is not None:
        enabled = bool(row["enabled"])
    else:
        enabled = True
    gated = _gate_reason(job_id)
    if gated:
        enabled = False
    return {"id": job_id, "label": label, "cron": cron, "enabled": enabled,
            "env_locked": env_enabled is not None, "gated": gated,
            "last_run": ({"ts": row["last_ts"], "ok": bool(row["last_ok"]),
                          "detail": row["last_detail"]}
                         if row and row.get("last_ts") else None)}


def _next_fire(cron: str, after: datetime) -> datetime:
    return croniter(cron, after).get_next(datetime)


def job_cron(job_id: str) -> str | None:
    reg = _registry()
    if job_id not in reg:
        return None
    return _effective(job_id, store.overrides().get(job_id), reg)["cron"]


def ensure_job_cron_allowed(job_id: str, cron: str):
    if job_id not in _registry():
        raise ValueError(f"unknown job '{job_id}'")
    if not croniter.is_valid(cron):
        raise ValueError("that schedule does not translate to a valid firing rule")
    pinned = _env_cron(job_id)
    if pinned and pinned != cron:
        raise ValueError("the schedule is pinned by the server environment and cannot change here")


def set_job_cron(job_id: str, cron: str):
    ensure_job_cron_allowed(job_id, cron)
    if _env_cron(job_id):
        return
    store.set_override(job_id, cron=cron)


def job_view(job_id: str) -> dict | None:
    reg = _registry()
    if job_id not in reg:
        return None
    view = _effective(job_id, store.overrides().get(job_id), reg)
    try:
        view["next_run"] = (_next_fire(view["cron"], datetime.now(TZ)).isoformat()
                            if view["enabled"] and ENABLED else None)
    except (ValueError, KeyError):
        view["next_run"] = None
    return view


def jobs_view() -> list[dict]:
    rows = store.overrides()
    out = []
    now = datetime.now(TZ)
    reg = _registry()
    for job_id in reg:
        j = _effective(job_id, rows.get(job_id), reg)
        try:
            j["next_run"] = _next_fire(j["cron"], now).isoformat() if j["enabled"] and ENABLED else None
        except (ValueError, KeyError):
            j["next_run"] = None
        out.append(j)
    return out


# ---- the loop -------------------------------------------------------------------------

_task: asyncio.Task | None = None
_running: set[str] = set()


def running_jobs() -> set[str]:
    """Job ids with a run in flight right now (scheduled or manual)."""
    return set(_running)


def _plural(n: int, word: str) -> str:
    return f"{n} {word}" + ("" if n == 1 else "s")


def summarize_outcome(job_id: str, result) -> str:
    """One or two plain-English sentences for a run's detail line: what ran, the outcome,
    the headline numbers. The raw run record is never serialized here; the structured
    payload stays available through the activity event, not this line."""
    if isinstance(result, str):
        return result.strip()[:300] or "Completed."
    if not isinstance(result, dict):
        return "Completed."
    r = result
    reg = _registry()
    label = reg[job_id][0] if job_id in reg else job_id
    if r.get("disabled"):
        why = (r.get("detail") or "").strip()
        return f"Skipped: {why}" if why else "Skipped: the controlling vein or feature is off."

    if job_id.startswith("vein_"):
        if r.get("skipped"):
            why = (r.get("detail") or r["skipped"]).strip()
            return f"Skipped: {why}."
        if r.get("ok") is False:
            where = f" at {r['block']}" if r.get("block") else ""
            why = (r.get("detail") or "").strip()
            return f"Vein run failed{where}" + (f": {why}." if why else ".")
        n = int(r.get("situations") or 0)
        if not n:
            return "Vein checked: quiet, nothing cleared the bar."
        return f"Vein checked: {_plural(n, 'situation')}, {_plural(int(r.get('cards') or 0), 'card')} posted."

    if job_id == "pulse":
        state = r.get("state") or "done"
        cards = len(r.get("injected") or [])
        killed = sum(int(v) for v in (r.get("gates") or {}).values())
        warnings = r.get("warnings") or []
        line = f"Pulse run {state}: shipped {_plural(cards, 'card')}"
        if killed:
            line += f", {_plural(killed, 'candidate')} cut by gates"
        line += "."
        if warnings:
            line += f" {_plural(len(warnings), 'warning')}."
        return line


    if job_id == "knowledge_groom":
        merged, promoted = len(r.get("merged") or []), len(r.get("promoted") or [])
        review = len(r.get("review") or [])
        gc = r.get("gc") or {}
        gc_n = int(gc.get("pending") or 0) + len(gc.get("orphans") or [])
        parts = []
        if merged:
            parts.append(f"merged {merged}")
        if promoted:
            parts.append(f"promoted {promoted}")
        if gc_n:
            parts.append(f"gc'd {gc_n}")
        if review:
            parts.append(f"{review} for review")
        return "Knowledge groom: " + (", ".join(parts) if parts else "nothing to groom") + "."

    if job_id == "updates":
        total = int(r.get("total") or 0)
        checked = f"Checked {_plural(total, 'component')}"
        if r.get("posted"):
            return f"{checked}; posted an updates card."
        cleared = int(r.get("cleared") or 0)
        if cleared:
            return f"{checked}; cleared {_plural(cleared, 'resolved card')}."
        return f"{checked}; all current."

    if job_id == "healthcheck":
        down = r.get("down") or []
        if not down:
            return "Service health probe: all services up."
        return f"Service health probe: {_plural(len(down), 'service')} down ({', '.join(down)})."

    if r.get("ok") is False:
        why = (r.get("detail") or r.get("error") or "").strip()
        return f"{label} did not complete" + (f": {why}." if why else ".")
    return f"{label} completed."


async def _fire(job_id: str, manual: bool = False):
    if job_id in _running:
        store.record_outcome(job_id, False, "skipped: previous run still in progress")
        return
    _running.add(job_id)
    try:
        gated = _gate_reason(job_id)  # re-check at fire time — the gate may have closed
        if gated:
            log.info("job %s skipped: %s", job_id, gated)
            return
        reg = _registry()
        if job_id not in reg:
            store.record_outcome(job_id, False, "skipped: the job's definition is gone")
            return
        handler = reg[job_id][2]
        result = await handler()
        store.record_outcome(job_id, True, summarize_outcome(job_id, result))
        log.info("job %s ok%s", job_id, " (manual)" if manual else "")
    except Exception as e:  # noqa: BLE001 — one bad job must never kill the loop
        store.record_outcome(job_id, False, f"{type(e).__name__}: {e}")
        log.warning("job %s failed: %s", job_id, e)
    finally:
        _running.discard(job_id)
        try:
            await escalate_failures(job_id)
        except Exception as e:  # noqa: BLE001 — alerting must never break the loop
            log.warning("failure escalation for %s failed: %s", job_id, e)


# Repeated failures surface as a System-vein card — one place to be told; the canvas
# shows the same state as node tint. One card per streak (no stacking), cleared the
# moment the job recovers.
FAIL_CARD_AFTER = int(os.environ.get("SCHEDULER_FAIL_CARD_AFTER", "3"))


def fail_streak(job_id: str) -> int:
    """Consecutive failures at the head of the job's run log (3-day window)."""
    n = 0
    for r in store.recent_runs(72):
        if r["job_id"] != job_id:
            continue
        if r["ok"]:
            break
        n += 1
    return n


def _job_label(job_id: str) -> str:
    reg = _registry()
    return reg[job_id][0] if job_id in reg else job_id


def _failure_card_title(job_id: str) -> str:
    return f"{_job_label(job_id)} keeps failing"


async def escalate_failures(job_id: str):
    """Post the failure-streak card (or clear it on recovery)."""
    from . import pulse_store, pulse_veins
    title = _failure_card_title(job_id)
    existing = [c for c in pulse_store.list_cards()
                if c.get("kind") == "status" and c.get("category") == "vera"
                and c.get("title") == title]
    streak = fail_streak(job_id)
    if streak == 0:
        for c in existing:  # recovered — the situation is over, the card goes with it
            pulse_store.delete_card(c["id"])
        return
    if streak < FAIL_CARD_AFTER or existing or not pulse_veins.is_enabled("status"):
        return
    last_detail = next((r["detail"] for r in store.recent_runs(72) if r["job_id"] == job_id), "")
    from .pulse import HOUSEHOLD, _inject
    label = _job_label(job_id)
    body = (f"**{label}** has failed {streak} runs in a row.\n\n"
            f"Last error: {last_detail or 'no detail recorded'}\n\n"
            "The flow's node on the Agentic canvas carries the same state.")
    await _inject(title, body, user_id=HOUSEHOLD, summary=f"{label} is failing repeatedly.",
                  kind="status", category="vera", severity="alert")


async def _loop():
    # next-fire computed per job and refreshed after each fire or config change; cheap
    # enough to recompute every poll, which also picks up runtime cron edits immediately.
    last_check = datetime.now(TZ)
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        now = datetime.now(TZ)
        rows = store.overrides()
        reg = _registry()
        for job_id in reg:
            j = _effective(job_id, rows.get(job_id), reg)
            if not j["enabled"]:
                continue
            try:
                due = _next_fire(j["cron"], last_check)
            except (ValueError, KeyError):
                continue  # bad cron edit — job reports next_run=None in the API
            if due <= now:
                asyncio.create_task(_fire(job_id))
        last_check = now


async def start():
    global _task
    if ENABLED and _task is None:
        _task = asyncio.create_task(_loop())
        log.info("scheduler running (%d jobs, poll %ds, tz %s)", len(builtin_jobs()), _POLL_SECONDS, TZ)
    elif not ENABLED:
        log.info("scheduler disabled (SCHEDULER_ENABLED=false)")


async def stop():
    global _task
    if _task is not None:
        _task.cancel()
        _task = None


# ---- API -------------------------------------------------------------------------------

class JobUpdate(BaseModel):
    cron: str | None = None
    enabled: bool | None = None


@router.get("/scheduler/jobs", tags=["scheduler"])
async def list_jobs():
    return {"scheduler_enabled": ENABLED, "jobs": jobs_view()}


@router.put("/scheduler/jobs/{job_id}", tags=["scheduler"])
async def update_job(job_id: str, req: JobUpdate):
    if job_id not in _registry():
        raise HTTPException(status_code=404, detail=f"unknown job '{job_id}'")
    if req.cron is not None:
        if not croniter.is_valid(req.cron):
            raise HTTPException(status_code=422, detail=f"invalid cron expression '{req.cron}'")
        if _env_cron(job_id):
            raise HTTPException(status_code=409, detail="schedule is pinned by env (SCHEDULE_*). Change it there")
    if req.enabled is not None and _env_enabled(job_id) is not None:
        raise HTTPException(status_code=409, detail="enabled is pinned by env (SCHEDULE_*_ENABLED). Change it there")
    store.set_override(job_id, cron=req.cron, enabled=req.enabled)
    return _effective(job_id, store.overrides().get(job_id)) | {
        "next_run": None if not ENABLED else _next_fire(
            _effective(job_id, store.overrides().get(job_id))["cron"], datetime.now(TZ)).isoformat()}


@router.post("/scheduler/jobs/{job_id}/run", tags=["scheduler"])
async def run_job(job_id: str):
    if job_id not in _registry():
        raise HTTPException(status_code=404, detail=f"unknown job '{job_id}'")
    gated = _gate_reason(job_id)
    if gated:
        raise HTTPException(status_code=409, detail=gated)
    asyncio.create_task(_fire(job_id, manual=True))
    return {"ok": True, "fired": job_id}
