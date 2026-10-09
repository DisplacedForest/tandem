from __future__ import annotations

import os
import signal
import sys
import uuid
from pathlib import Path
from typing import Any

from .confirmed_invocations import ConfirmedInvocationFixture, FixtureInvocationAuthority, InvocationDenied, canonical, strict_json


def serve(root: Path) -> None:
    fixture: ConfirmedInvocationFixture | None = None
    capability = str(uuid.uuid4())
    try:
        while raw := sys.stdin.buffer.readline(32770):
            if len(raw) > 32768 or not raw.endswith(b'\n'):
                return
            request: Any = None
            try:
                request = strict_json(raw.decode('utf-8').rstrip('\n'), 32768)
                if not isinstance(request, dict) or type(request.get('id')) is not int or not isinstance(request.get('method'), str) or not isinstance(request.get('params'), dict) or set(request) != {'id', 'method', 'params'}:
                    raise InvocationDenied('Invalid fixture request')
                method, params = request['method'], request['params']
                expected = {'open': {'binding', 'create'}, 'prepare': {'binding'}, 'inspect': {'scope', 'taskID'}, 'cancel': {'scope', 'taskID', 'capability'}, 'respond': {'scope', 'taskID', 'decisionID', 'replyID', 'approved', 'capability'}, 'dispatch': {'scope', 'taskID', 'capability'}, 'crash': {'scope', 'taskID', 'capability', 'phase'}, 'count': set(), 'revoke': {'capability'}}
                if method not in expected or set(params) != expected[method]:
                    raise InvocationDenied('Unsupported fixture method')
                if method == 'open':
                    if fixture is not None or type(params['create']) is not bool:
                        raise InvocationDenied('Fixture already opened')
                    fixture = ConfirmedInvocationFixture(root, FixtureInvocationAuthority(params['binding']), create=params['create'])
                    value: Any = {'capability': capability}
                else:
                    if fixture is None:
                        raise InvocationDenied('Fixture is not open')
                    if 'capability' in params and params['capability'] != capability:
                        raise InvocationDenied('Host decision capability required')
                    if method == 'prepare':
                        value = fixture.prepare(params['binding'])
                    elif method == 'inspect':
                        value = fixture.inspect(params['scope'], params['taskID'])
                    elif method == 'cancel':
                        value = fixture.cancel(params['scope'], params['taskID'])
                    elif method == 'respond':
                        value = fixture.decisions.respond(params['scope'], params['taskID'], params['decisionID'], params['replyID'], params['approved'])
                    elif method == 'dispatch':
                        value = fixture.dispatch_synthetic(params['scope'], params['taskID'])
                    elif method == 'crash':
                        if params['phase'] not in {'intent', 'effect'}:
                            raise InvocationDenied('Unknown crash phase')
                        def kill() -> None:
                            os.kill(os.getpid(), signal.SIGKILL)
                        fixture.dispatch_synthetic(params['scope'], params['taskID'], before_effect=kill if params['phase'] == 'intent' else None, after_effect=kill if params['phase'] == 'effect' else None)
                        raise InvocationDenied('Crash fixture did not terminate')
                    elif method == 'count':
                        value = fixture.effect_count()
                    elif method == 'revoke':
                        fixture.authority.revoke()
                        value = None
                response = {'id': request['id'], 'ok': True, 'value': value}
            except Exception:
                response = {'id': request.get('id') if isinstance(locals().get('request'), dict) else None, 'ok': False, 'error': 'rejected'}
            encoded = canonical(response).encode() + b'\n'
            if len(encoded) > 32768:
                return
            sys.stdout.buffer.write(encoded)
            sys.stdout.buffer.flush()
    finally:
        if fixture is not None:
            fixture.close()


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != '--isolated-fixture-stdio':
        raise SystemExit(2)
    serve(Path(sys.argv[2]))
