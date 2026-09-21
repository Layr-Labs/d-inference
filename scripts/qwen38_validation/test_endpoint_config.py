"""CPU-only tests; ephemeral synthetic loopback server, no model or dev secrets."""
import http.server
import ipaddress
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

import endpoint_config as config

class EndpointConfigurationTests(unittest.TestCase):
    def test_explicit_loopback_origin_only(self):
        origin = 'http://' + str(ipaddress.IPv4Address(0x7f000001)) + ':49152'
        self.assertEqual(config.base_url({config.BASE_VARIABLE: origin + '/'}), origin)
        for value in ('', 'https://example.invalid', 'http://example.invalid:80',
                      origin + '/v1', origin + '?token=x', origin + '#fragment',
                      origin.replace('http://', 'http://user:pass@'), origin.rsplit(':', 1)[0]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                config.base_url({config.BASE_VARIABLE: value})

    def test_key_file_is_explicit_private_and_not_followed(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-key-fixture-') as temporary:
            key = Path(temporary) / 'fixture'
            key.write_text('synthetic-test-credential\n')
            key.chmod(0o600)
            with patch.dict(os.environ, {config.KEY_VARIABLE: str(key)}):
                self.assertEqual(config.headers()['Authorization'], 'Bearer synthetic-test-credential')
                key.chmod(0o644)
                with self.assertRaises(ValueError): config.headers()
                key.chmod(0o600)
                key.write_text('bad\nheader')
                with self.assertRaises(ValueError): config.headers()
            link = Path(temporary) / 'link'
            link.symlink_to(key)
            with patch.dict(os.environ, {config.KEY_VARIABLE: str(link)}), self.assertRaises(OSError):
                config.headers()

    def test_redirect_is_not_followed(self):
        calls = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                self.send_response(302)
                self.send_header('Location', '/must-not-follow')
                self.end_headers()
            def log_message(self, *args): pass
        host = str(ipaddress.IPv4Address(0x7f000001))
        server = http.server.ThreadingHTTPServer((host, 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                config.open_request(urllib.request.Request(f'http://{host}:{server.server_port}/first'))
            caught.exception.close()
            self.assertEqual(calls, ['/first'])
        finally:
            server.shutdown(); server.server_close(); thread.join()

if __name__ == '__main__': unittest.main()
