import json

NAMES_TEMPLATE = (
    "{%- set ns = namespace(rows=[]) -%}"
    "{%- for s in states -%}"
    "{%- set ns.rows = ns.rows + [[s.entity_id, entity_name(s.entity_id), "
    "device_name(s.entity_id), area_name(s.entity_id)]] -%}"
    "{%- endfor -%}"
    "{{ ns.rows | tojson }}"
)


def _clean(v) -> str:
    return v.strip() if isinstance(v, str) else ""


def humanize_entity_id(eid: str) -> str:
    obj = eid.split(".", 1)[1] if "." in eid else eid
    return " ".join(w.capitalize() for w in obj.replace("-", "_").split("_") if w) or eid


def compose(entity_name, device_name) -> str:
    en, dn = _clean(entity_name), _clean(device_name)
    if not dn:
        return en
    if not en:
        return dn
    if en.lower() == dn.lower() or en.lower().startswith(dn.lower() + " "):
        return en
    return f"{dn} {en}"


def parse_names(rows) -> dict:
    out = {}
    for r in rows or []:
        if not isinstance(r, (list, tuple)) or len(r) < 4 or not isinstance(r[0], str):
            continue
        out[r[0]] = {"entity": _clean(r[1]), "device": _clean(r[2]), "area": _clean(r[3])}
    return out


def display_name(state: dict, names: dict | None = None) -> str:
    eid = state.get("entity_id") or ""
    info = (names or {}).get(eid)
    if info:
        full = compose(info.get("entity"), info.get("device"))
        if full:
            return full
    fn = _clean((state.get("attributes") or {}).get("friendly_name"))
    if fn:
        return fn
    return humanize_entity_id(eid) if eid else ""


def name_candidates(state: dict, names: dict | None = None) -> list:
    eid = state.get("entity_id") or ""
    info = (names or {}).get(eid) or {}
    full = compose(info.get("entity"), info.get("device"))
    area = _clean(info.get("area"))
    cands = [
        display_name(state, names),
        full,
        _clean(info.get("entity")),
        _clean(info.get("device")),
        f"{area} {full}" if area and full and not full.lower().startswith(area.lower()) else "",
        _clean((state.get("attributes") or {}).get("friendly_name")),
        humanize_entity_id(eid) if eid else "",
    ]
    seen, out = set(), []
    for c in cands:
        k = c.lower()
        if c and k not in seen:
            seen.add(k)
            out.append(c)
    return out


async def fetch_names(session, url: str, token: str, timeout: float = 20) -> dict:
    if not url or not token:
        return {}
    try:
        import aiohttp
        async with session.post(f"{url}/api/template", json={"template": NAMES_TEMPLATE},
                                headers={"Authorization": f"Bearer {token}"},
                                timeout=aiohttp.ClientTimeout(total=timeout)) as r:
            if r.status != 200:
                return {}
            return parse_names(json.loads(await r.text()))
    except Exception:
        return {}
