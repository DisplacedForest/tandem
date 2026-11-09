try:
    from .action_registry import SPEC
except ImportError:
    from action_registry import SPEC


def is_autonomous(verb: str) -> bool:
    """True only for verbs explicitly enrolled in the free (no-confirm) lane."""
    return bool((SPEC.get(verb) or {}).get("autonomous"))


def check_autonomy_invariant(spec: dict) -> None:
    """A verb may be autonomous only if it is genuinely cheap to be wrong about:
    risk in {none, low} AND reversible. Raises so a dangerous verb can never be
    flagged free, even by mistake."""
    for verb, s in spec.items():
        if s.get("autonomous") and not (s["risk"] in ("none", "low") and s["reversible"]):
            raise AssertionError(
                f"{verb} cannot be autonomous: requires risk in {{none,low}} and reversible "
                f"(got risk={s['risk']!r}, reversible={s['reversible']!r})")


check_autonomy_invariant(SPEC)
