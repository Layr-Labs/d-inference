#!/usr/bin/env python3
"""Real-socket adversarial metadata tests; no models, credentials or inference.

Requires a built connect-probe and a FREE 127.0.0.1:11434. Never stops Ollama.
The hostile server is a test fixture, not an installed Ollama runtime.
"""
import http.server
import json
import pathlib
import subprocess
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / '.build/debug/connect-probe'
requests = []
redirect_hits = []
mode = 'valid'


class RedirectTarget(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        redirect_hits.append(self.path)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


class HostileOllama(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.command, self.path, self.headers.get('Authorization')))
        if mode == 'authentication':
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Hostile Ollama"')
            self.end_headers()
            return
        if mode == 'redirect':
            self.send_response(302)
            self.send_header('Location', f'http://127.0.0.1:{target.server_port}/capture')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        if mode == 'large-header':
            self.send_header('Content-Length', str(2**30))
            self.end_headers()
            return
        self.end_headers()
        if mode == 'large-stream':
            try:
                for _ in range(130):
                    self.wfile.write(b' ' * 16384)
            except (ConnectionResetError, BrokenPipeError):
                pass
            return
        if mode == 'invalid':
            self.wfile.write(b'{invalid')
            return
        model = {'name': 'qwen3.8:27b;$(echo should-not-execute)', 'size': 16_000_000_000,
                 'digest': 'untrusted-claim', 'details': {'format': 'gguf'},
                 'app_attest_authorized': True, 'endpoint': f'http://127.0.0.1:{target.server_port}/capture'}
        self.wfile.write(json.dumps({'models': [model] if self.path == '/api/tags' else []}).encode())

    def do_POST(self):
        requests.append((self.command, self.path, self.headers.get('Authorization')))
        self.send_response(500)
        self.end_headers()

    def log_message(self, *args):
        pass


if not PROBE.exists():
    raise SystemExit('Build first: swift build --package-path experiments/ollama-connect')
target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), RedirectTarget)
try:
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 11434), HostileOllama)
except OSError as exc:
    target.server_close()
    raise SystemExit('Port 11434 is occupied; leave the existing Ollama service running and run these tests on an isolated host.') from exc
for service in [target, server]:
    threading.Thread(target=service.serve_forever, daemon=True).start()
try:
    for mode in ['valid', 'redirect', 'authentication', 'large-header', 'large-stream', 'invalid']:
        requests.clear()
        result = subprocess.run([str(PROBE), '--ollama-only'], capture_output=True, text=True, timeout=25, check=True)
        payload = json.loads(result.stdout)
        assert payload['reachable'] == (mode == 'valid'), (mode, payload)
        assert requests and all(method == 'GET' and path in ['/api/tags', '/api/ps'] and credential is None for method, path, credential in requests), requests
        assert not redirect_hits, redirect_hits
        if mode == 'valid':
            assert [path for _, path, _ in requests] == ['/api/tags', '/api/ps']
        print(json.dumps({'case': mode, 'passed': True, 'requests': [path for _, path, _ in requests], 'inference_requests': 0, 'redirect_target_requests': 0}))
finally:
    for service in [server, target]:
        service.shutdown()
        service.server_close()
