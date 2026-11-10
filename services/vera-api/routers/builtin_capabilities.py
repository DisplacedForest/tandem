import sys
import threading

_lock = threading.RLock()
_state = {"loading": False, "loaded": False}


def load() -> None:
    if _state["loaded"]:
        return
    with _lock:
        if _state["loaded"] or _state["loading"]:
            return
        from . import action_registry, scheduler
        before = set(sys.modules)
        actions_snapshot = action_registry.snapshot()
        jobs_snapshot = scheduler.snapshot()
        _state["loading"] = True
        try:
            from . import authoring, conversation_extract, home, home_model, home_reconcile
            from . import kitchen, knowledge_actions, knowledge_groom, learn
            from . import media_curation, overseerr, pulse, updates
        except BaseException:
            action_registry.restore(actions_snapshot)
            scheduler.restore(jobs_snapshot)
            prefix = f"{__package__}."
            package = sys.modules[__package__]
            for name in set(sys.modules) - before:
                if name.startswith(prefix):
                    sys.modules.pop(name, None)
                    package.__dict__.pop(name[len(prefix):], None)
            raise
        else:
            _state["loaded"] = True
        finally:
            _state["loading"] = False
