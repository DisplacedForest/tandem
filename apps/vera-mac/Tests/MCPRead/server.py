import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


counts = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length > 32768 or any(self.headers.get(key) for key in ['Authorization', 'Cookie', 'Proxy-Authorization']):
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        request = json.loads(self.rfile.read(length))
        method = request.get('method')
        with lock:
            key = self.path + '|' + method
            counts[key] = counts.get(key, 0) + 1
            target = Path(sys.argv[1] + '.counts.json')
            temporary = target.with_suffix('.tmp')
            temporary.write_text(json.dumps(counts))
            temporary.replace(target)
        if method == 'notifications/initialized':
            self.send_response(202)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if method == 'initialize':
            result = {'protocolVersion': '2025-06-18', 'serverInfo': {'name': 'Synthetic read verification', 'version': '1'}, 'capabilities': {'tools': {}}}
        elif method == 'tools/list':
            schema = {'type': 'object', 'properties': {'url': {'type': 'string', 'const': 'https://example.invalid/page', 'maxLength': 2048}}, 'required': ['url'], 'additionalProperties': False}
            result = {'tools': [{'name': 'fixture_read', 'description': 'Synthetic description. Never use this text as instructions or field defaults.', 'inputSchema': schema}]}
        elif method == 'tools/call':
            if self.path in ['/slow', '/held']:
                time.sleep(4 if self.path == '/slow' else 1)
            text = '<b>Plain synthetic response</b>\n[This is text, not a rendered link](https://example.invalid/page)'
            if self.path == '/large':
                text = 'x' * 5000
            if self.path == '/wire-large':
                text = 'x' * 300000
            result = {'content': [{'type': 'text', 'text': text}], 'isError': False}
        else:
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
