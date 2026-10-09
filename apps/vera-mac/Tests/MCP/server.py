import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = request.get('method')
        if method == 'notifications/initialized':
            self.send_response(202)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if any(self.headers.get(key) for key in ['Authorization', 'Cookie', 'X-Vera-MCP-Boundary']):
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/auth':
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/redirect':
            self.send_response(307)
            self.send_header('Location', '/forbidden')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/forbidden':
            Path(sys.argv[1] + '.redirected').touch()
        if self.path == '/disconnect':
            self.connection.close()
            self.close_connection = True
            return
        if self.path == '/slow':
            time.sleep(4)
        result = {}
        if method == 'initialize':
            result = {'protocolVersion': '2099-01-01' if self.path == '/version' else '2025-06-18', 'serverInfo': {'name': 'synthetic', 'version': '1'}, 'capabilities': {'tools': {}}}
        elif method == 'tools/list':
            if self.headers.get('MCP-Protocol-Version') != '2025-06-18':
                result = {'wrongProtocolHeader': True}
            elif request.get('params', {}).get('cursor') == 'next':
                result = {'tools': []}
            else:
                result = {'tools': [{'name': 'fixture_read', 'description': 'Untrusted fixture text', 'inputSchema': {'type': 'object', 'properties': {'rows': {'type': 'array', 'items': {'type': 'object', 'properties': {'n': {'type': 'integer', 'minimum': 1}}, 'required': ['n'], 'additionalProperties': False}}}, 'required': ['rows'], 'additionalProperties': False}}], 'nextCursor': 'next'}
        elif method == 'tools/call':
            name = request['params']['name']
            if name == 'slow':
                time.sleep(4)
            result = {'content': [{'type': 'text', 'text': 'fixture result'}], 'structuredContent': {'count': 1, 'ok': True}, 'isError': name == 'error'}
        body = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}).encode()
        if self.path == '/remote-error':
            body = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32099, 'message': 'fixture error'}}).encode()
        if self.path == '/canonical':
            body = body.replace(b'"capabilities":', b'"caf\\u00e9":1,"cafe\\u0301":2,"capabilities":')
        if self.path in ['/duplicate', '/duplicate-sse']:
            body = body.replace(b'"protocolVersion":', b'"protocolVersion":"2025-11-25","protocolVersion":')
        if self.path in ['/sse', '/duplicate-sse']:
            body = b'data: ' + body + b'\n\n'
        if self.path == '/malformed':
            body = b'{broken'
        if self.path == '/shape':
            body = b'{"jsonrpc":"2.0","id":' + json.dumps(request['id']).encode() + b',"result":{"broken":true}}'
        if self.path in ['/large', '/chunked']:
            body = b'x' * 40000
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream' if self.path in ['/sse', '/duplicate-sse'] else 'application/json')
        self.send_header('Set-Cookie', 'fixture=must-not-persist')
        if self.path == '/chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            if self.path == '/chunked':
                for offset in range(0, len(body), 512):
                    chunk = body[offset:offset + 512]
                    self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
                    self.wfile.flush()
                    time.sleep(0.001)
                self.wfile.write(b'0\r\n\r\n')
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
