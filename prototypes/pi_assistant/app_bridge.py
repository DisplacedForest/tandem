import asyncio
import os
import socket
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'services/vera-api'))

from pi_assistant.app_model import AppModelTransport, decode_frame
from pi_assistant.bridge import create_app


async def serve(boot: dict) -> None:
    import uvicorn
    transport = AppModelTransport(boot['channel'], boot['profile'], boot['request_timeout'], boot['transport'])
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', boot['port']))
        listener.listen(16)
        listener.setblocking(False)
        app = create_app(Path(boot['root']), boot['node'], instance_id=boot['channel'], model_transport=transport, ui_capability=boot['ui_capability'])
        server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level='warning', timeout_graceful_shutdown=2))
        async def supervise() -> None:
            while not server.started:
                if transport.closed.is_set():
                    server.should_exit = True
                    return
                await asyncio.sleep(.01)
            transport.send({'op': 'ready', 'channel': boot['channel'], 'port': listener.getsockname()[1]})
            await transport.closed.wait()
            server.should_exit = True
        watcher = asyncio.create_task(supervise())
        try:
            await server.serve(sockets=[listener])
        finally:
            watcher.cancel()
            await asyncio.gather(watcher, return_exceptions=True)


def main() -> None:
    if sys.argv[1:] not in (['--app-owned'], ['--app-owned-mock']) or not all(stat.S_ISFIFO(os.fstat(fd).st_mode) for fd in (0, 1)):
        raise ValueError('private app channel required')
    os.umask(0o077)
    if os.getpgrp() != os.getpid():
        os.setsid()
    boot = decode_frame(sys.stdin.buffer.readline(65538))
    if set(boot) != {'op', 'transport', 'channel', 'profile', 'ui_capability', 'root', 'node', 'port', 'request_timeout'} or boot['op'] != 'initialize' or boot['transport'] not in ('app-owned-mock', 'app-owned-provider-fixture', 'app-owned-openrouter'):
        raise ValueError('app bootstrap required')
    cap = boot['ui_capability']
    if not isinstance(cap, str) or len(cap) != 72 or any(c not in '0123456789abcdef-' for c in cap):
        raise ValueError('capability required')
    if type(boot['port']) is not int or not 0 <= boot['port'] <= 65535:
        raise ValueError('port')
    root = Path(boot['root'])
    home = Path.home() / '.vera'
    if not root.is_absolute() or root != root.resolve() or home == root or home in root.parents or root in home.parents:
        raise ValueError('isolated root required')
    for file in root.rglob('*') if root.exists() else ():
        info = file.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1):
            raise ValueError('private runtime required')
    node = Path(boot['node'])
    if not node.is_absolute() or not os.access(node, os.X_OK):
        raise ValueError('node')
    asyncio.run(serve(boot))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        sys.stderr.write('App-owned runtime unavailable\n')
        sys.exit(1)
