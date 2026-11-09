_state = {"loading": False, "loaded": False}


def load() -> None:
    if _state["loaded"] or _state["loading"]:
        return
    _state["loading"] = True
    try:
        from . import authoring, conversation_extract, home, home_model, home_reconcile
        from . import kitchen, knowledge_actions, knowledge_groom, learn
        from . import media_curation, overseerr, pulse, updates
        _state["loaded"] = True
    finally:
        _state["loading"] = False
