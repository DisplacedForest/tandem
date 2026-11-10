import threading
from collections.abc import Awaitable, Callable
from typing import Any

Executor = Callable[[dict], Awaitable[Any]]
ItemDecisionHook = Callable[[dict, str, bool], None]

SPEC: dict[str, dict] = {}
EXECUTORS: dict[str, Executor] = {}
ORDER: dict[str, int] = {}
OWNERS: dict[str, str] = {}
ITEM_DECISION_HOOKS: list[ItemDecisionHook] = []
CATALOG_EXTRAS: dict[str, Callable[[], Any]] = {}
_HOOK_ORDER: list[tuple[int, ItemDecisionHook]] = []
_write_lock = threading.RLock()


def _check_autonomy(verb: str, s: dict) -> None:
    if s.get("autonomous") and not (s["risk"] in ("none", "low") and s["reversible"]):
        raise AssertionError(
            f"{verb} cannot be autonomous: requires risk in {{none,low}} and reversible "
            f"(got risk={s['risk']!r}, reversible={s['reversible']!r})")


def _resort() -> None:
    verbs = sorted(ORDER, key=lambda v: ORDER[v])
    specs = {v: SPEC[v] for v in verbs if v in SPEC}
    executors = {v: EXECUTORS[v] for v in verbs if v in EXECUTORS}
    extra_specs = {v: s for v, s in SPEC.items() if v not in ORDER}
    extra_executors = {v: f for v, f in EXECUTORS.items() if v not in ORDER}
    SPEC.clear()
    SPEC.update(specs)
    SPEC.update(extra_specs)
    EXECUTORS.clear()
    EXECUTORS.update(executors)
    EXECUTORS.update(extra_executors)


def register_action(verb: str, *, validate: Callable[[dict], str | None], preview: Callable[[dict], str],
                    risk: str, reversible: bool, autonomous: bool, order: int, executor: Executor,
                    **extra: Any) -> None:
    owner = getattr(executor, "__module__", "") or ""
    entry = {"validate": validate, "preview": preview, "risk": risk, "reversible": reversible,
             "autonomous": autonomous, **extra}
    _check_autonomy(verb, entry)
    with _write_lock:
        if verb in ORDER and OWNERS.get(verb) != owner:
            raise ValueError(f"action verb already registered: {verb}")
        SPEC[verb] = entry
        EXECUTORS[verb] = executor
        ORDER[verb] = order
        OWNERS[verb] = owner
        _resort()


def unregister_action(verb: str) -> None:
    with _write_lock:
        SPEC.pop(verb, None)
        EXECUTORS.pop(verb, None)
        ORDER.pop(verb, None)
        OWNERS.pop(verb, None)


def register_item_decision_hook(fn: ItemDecisionHook, *, order: int) -> None:
    with _write_lock:
        identity = (getattr(fn, "__module__", ""), getattr(fn, "__qualname__", ""))
        _HOOK_ORDER[:] = [(o, f) for o, f in _HOOK_ORDER
                          if (getattr(f, "__module__", ""), getattr(f, "__qualname__", "")) != identity]
        _HOOK_ORDER.append((order, fn))
        _HOOK_ORDER.sort(key=lambda pair: pair[0])
        ITEM_DECISION_HOOKS.clear()
        ITEM_DECISION_HOOKS.extend(fn for _, fn in _HOOK_ORDER)


def register_catalog_extra(key: str, fn: Callable[[], Any]) -> None:
    with _write_lock:
        current = CATALOG_EXTRAS.get(key)
        same_owner = current is not None and getattr(current, "__module__", "") == getattr(fn, "__module__", None)
        if key == "verbs" or (current is not None and not same_owner):
            raise ValueError(f"catalog key already registered: {key}")
        CATALOG_EXTRAS[key] = fn


def load_builtin() -> None:
    from . import builtin_capabilities
    builtin_capabilities.load()
