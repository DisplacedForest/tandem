from . import action_registry
from . import groom_common as gcm
from . import knowledge_store as ks


def _v_kset(args):
    if not args.get("type") or not args.get("name"):
        return "knowledge.set needs type and name"
    return None


def _p_kset(args):
    return f"Record {args.get('type')} '{args.get('name')}': {args.get('attrs') or {}}"


def _v_kdel(args):
    if not args.get("entity_id") and not (args.get("type") and args.get("name")):
        return "knowledge.delete needs entity_id or type+name"
    return None


def _p_kdel(args):
    target = args.get("entity_id") or f"{args.get('type')}:{args.get('name')}"
    return f"Delete {target}"


def _v_kreverify(args):
    if not args.get("entity_id"):
        return "knowledge.reverify needs entity_id"
    return None


def _p_kreverify(args):
    return f"Re-verify {args.get('entity_id')} (stamp last_verified = now)"


def _v_kpromote(args):
    if not args.get("type") or not args.get("schema"):
        return "knowledge.promote needs type and schema"
    return None


def _p_kpromote(args):
    req = (args.get("schema") or {}).get("required") or []
    return f"Codify the '{args.get('type')}' type's schema (required: {', '.join(req) or 'none'})"


async def _x_knowledge_set(args):
    p = ks.propose("set", type=args.get("type"), name=args.get("name"),
                   attrs=args.get("attrs") or {}, source="action", actor="vera")
    return ks.commit(p["token"])


async def _x_knowledge_delete(args):
    p = ks.propose("delete", entity_id=args.get("entity_id"), type=args.get("type"),
                   name=args.get("name"), source="action", actor="vera")
    return ks.commit(p["token"])


async def _x_knowledge_reverify(args):
    import time as _t
    eid = args.get("entity_id")
    cur = ks.get(eid)
    if not cur:
        return {"ok": False, "error": f"unknown entity {eid}"}
    p = ks.propose("set", entity_id=eid, type=cur["type"], name=cur["name"],
                   attrs={"last_verified": int(_t.time())}, source="action", actor="vera")
    return ks.commit(p["token"])


async def _x_knowledge_promote(args):
    return ks.promote(args.get("type"), args.get("schema") or {}, by="owner")


def _suppress_rejected_promotion(item: dict, decision: str, ok: bool) -> None:
    verb = (item.get("action") or {}).get("verb")
    if decision == "skip" and verb == "knowledge.promote":
        gcm.suppress("knowledge", "promote", (item.get("action") or {}).get("args", {}).get("type", ""),
                     reason="flagged proposal rejected")


action_registry.register_action(
    "knowledge.set", validate=_v_kset, preview=_p_kset, risk="low", reversible=True,
    autonomous=False, order=30, executor=_x_knowledge_set,
    summary="record or update a durable home fact",
    args='{"type": "...", "name": "...", "attrs": {...}}')
action_registry.register_action(
    "knowledge.delete", validate=_v_kdel, preview=_p_kdel, risk="medium", reversible=False,
    autonomous=False, order=40, executor=_x_knowledge_delete,
    summary="remove a durable home fact",
    args='{"entity_id": "..."} or {"type": "...", "name": "..."}')
action_registry.register_action(
    "knowledge.reverify", validate=_v_kreverify, preview=_p_kreverify, risk="none", reversible=True,
    autonomous=False, order=50, executor=_x_knowledge_reverify,
    summary="re-stamp a fact's last_verified to now",
    args='{"entity_id": "..."}')
action_registry.register_action(
    "knowledge.promote", validate=_v_kpromote, preview=_p_kpromote, risk="low", reversible=True,
    autonomous=False, order=60, executor=_x_knowledge_promote,
    summary="codify a knowledge type's schema",
    args='{"type": "...", "schema": {...}}')
action_registry.register_item_decision_hook(_suppress_rejected_promotion, order=20)
