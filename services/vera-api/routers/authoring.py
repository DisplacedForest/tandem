import re

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from . import action_registry
from . import authoring_store as store

router = APIRouter()

def _slug(s):
    return re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-") or "skill"


async def _skill_upsert(sid, name, description, content):
    store.skill_upsert(sid, name, description or "", content)
    return sid


class SkillBody(BaseModel):
    name: str
    content: str
    id: str | None = None
    description: str | None = None


@router.post("/authoring/skill", tags=["authoring"])
async def author_skill(b: SkillBody):
    sid = b.id or _slug(b.name)
    from . import actions
    ok, err = actions._stage("authoring.skill_upsert",
                             {"name": b.name, "content": b.content, "id": sid,
                              "description": b.description},
                             source="self_author", actor="vera", chat_id=None, message_id=None)
    if err:
        raise HTTPException(400, err.get("error", "invalid skill proposal"))
    return {"proposed": True, "token": ok["token"], "preview": ok["preview"],
            "message": "proposed, awaiting confirmation"}


@router.get("/authoring/skills", tags=["authoring"])
async def list_skills():
    return {"skills": store.skill_list()}


@router.get("/authoring/skills/{sid}", tags=["authoring"])
async def get_skill(sid: str):
    s = store.skill_get(sid)
    if not s:
        raise HTTPException(404, "skill not found")
    return s


@router.get("/authoring/revisions", tags=["authoring"])
async def list_revisions(target: str):
    return {"revisions": store.revisions(target)}


class RevertBody(BaseModel):
    rev_id: int


@router.post("/authoring/revert", tags=["authoring"])
async def revert(b: RevertBody):
    r = store.get(b.rev_id)
    if not r:
        raise HTTPException(404, "revision not found")
    target = r["target"]
    if not target.startswith("skill:"):
        raise HTTPException(400, "can only revert skill targets")
    sid = target.split(":", 1)[1]
    cur = store.skill_get(sid)
    name = (cur or {}).get("name") or sid
    desc = (cur or {}).get("description") or ""
    store.snapshot(target, r["content"], note=f"revert to #{b.rev_id}")
    await _skill_upsert(sid, name, desc, r["content"])
    return {"ok": True, "id": sid, "reverted_to": b.rev_id}


def _v_skill(args):
    if not (args.get("name") or "").strip():
        return "skill name required"
    if not (args.get("content") or "").strip():
        return "skill content required"
    return None


def _p_skill(args):
    name = (args.get("name") or "(unnamed)").strip()
    content = (args.get("content") or "").strip()
    opening = content.splitlines()[0][:80] if content else ""
    return f"Author skill '{name}' ({len(content)} chars). Opens: {opening}"


async def _x_skill_upsert(args):
    sid = (args.get("id") or "").strip() or _slug(args.get("name") or "")
    content = args.get("content") or ""
    store.snapshot(f"skill:{sid}", content, note=args.get("name") or sid)
    await _skill_upsert(sid, args.get("name"), args.get("description"), content)
    return {"ok": True, "id": sid}


action_registry.register_action(
    "authoring.skill_upsert", validate=_v_skill, preview=_p_skill, risk="high", reversible=True,
    autonomous=False, order=10, executor=_x_skill_upsert,
    summary="create or modify a skill (Vera's own cognition config)",
    args='{"name": "...", "content": "...", "id": "...", "description": "..."}')
