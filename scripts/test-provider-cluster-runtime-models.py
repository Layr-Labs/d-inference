#!/usr/bin/env python3
"""The release's model-metadata fetch against a local HTTP registry (no network, no weights)."""
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('models', Path(__file__).with_name('provider-cluster-runtime-models.py'))
MODELS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODELS)

ARTIFACT = 'a' * 64
OTHER = 'b' * 64
CONFIG = b'{"model_type": "qwen3_5"}'


def manifest(model_id, aggregate=ARTIFACT, config=CONFIG, created='2026-09-03T00:00:00Z', files=None):
    entries = files if files is not None else [
        {'path': 'config.json', 'size_bytes': len(config), 'sha256': hashlib.sha256(config).hexdigest()},
        {'path': 'model.safetensors', 'size_bytes': 10, 'sha256': 'c' * 64}]
    return json.dumps({'model_id': model_id, 'aggregate_sha256': aggregate, 'created_at': created,
                       'files': entries}).encode()


class Registry(http.server.BaseHTTPRequestHandler):
    routes = {}
    hits = []

    def do_GET(self):
        Registry.hits.append((self.path, self.headers.get('User-Agent')))
        responses = Registry.routes.get(self.path, [(404, b'missing', {})])
        status, body, headers = responses.pop(0) if len(responses) > 1 else responses[0]
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class FetchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Registry)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f'http://127.0.0.1:{cls.server.server_address[1]}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Registry.routes, Registry.hits = {}, []
        sleep = patch.object(MODELS.time, 'sleep')
        self.sleeps = sleep.start()
        self.addCleanup(sleep.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.coordinator, self.cdn = self.base + '/dev', self.base + '/cdn'
        self.listed = [{'runtime_model_id': 'registered_qwen35_9b', 'artifact_sha256': ARTIFACT}]

    def route(self, path, body, status=200, headers=None):
        Registry.routes[path] = [(status, body, headers or {})]

    def catalog(self, *entries):
        self.route('/dev/v1/models/catalog', json.dumps({'models': list(entries)}).encode())

    def entry(self, model_id, prefix, aggregate=ARTIFACT, cdn=None, coordinator=None, config=CONFIG):
        """A catalog entry with its CDN manifest, coordinator manifest and config.json."""
        self.route(f'/cdn/{prefix}/manifest.json', cdn if cdn is not None else manifest(model_id, aggregate))
        self.route('/dev/v1/models/catalog/manifest/' + MODELS.model_id_path(model_id),
                   coordinator if coordinator is not None else manifest(model_id, aggregate, created='other'))
        self.route(f'/cdn/{prefix}/config.json', config)
        return {'id': model_id, 'r2_prefix': prefix, 'aggregate_sha256': aggregate}

    def fetch(self, listed=None):
        return MODELS.candidates(self.listed if listed is None else listed, self.coordinator, self.cdn)

    def test_both_encodings_of_every_matching_entry_become_candidates_cdn_first(self):
        qwen = self.entry('Qwen3.5-9B', 'v2/Qwen3.5-9B--3e3c/2026-09-03-r1')
        twin = self.entry('Qwen3.5-9B-copy', 'v2/copy/r1')
        self.catalog(qwen, twin, self.entry('other', 'v2/other/r1', aggregate=OTHER))
        found, skipped, failures = self.fetch()
        self.assertEqual((skipped, failures), ([], []))
        self.assertEqual([(json.loads(m)['model_id'], json.loads(m)['created_at']) for m, _ in found[ARTIFACT]],
                         [('Qwen3.5-9B', '2026-09-03T00:00:00Z'), ('Qwen3.5-9B', 'other'),
                          ('Qwen3.5-9B-copy', '2026-09-03T00:00:00Z'), ('Qwen3.5-9B-copy', 'other')])
        self.assertTrue(all(config == CONFIG for _, config in found[ARTIFACT]))
        self.assertFalse(any('/v2/other/' in path for path, _ in Registry.hits))
        self.assertTrue(all(agent == MODELS.USER_AGENT for _, agent in Registry.hits))
        # config.json is fetched once per entry, never a weight file.
        self.assertEqual(sum(path.endswith('/config.json') for path, _ in Registry.hits), 2)
        self.assertFalse(any('safetensors' in path for path, _ in Registry.hits))

    def test_identical_encodings_are_kept_once(self):
        same = manifest('Qwen3.5-9B')
        self.catalog(self.entry('Qwen3.5-9B', 'v2/q/r1', coordinator=same))
        found, skipped, failures = self.fetch()
        self.assertEqual((failures, skipped, [m for m, _ in found[ARTIFACT]]), ([], [], [same]))

    def test_a_listed_artifact_the_catalog_lacks_is_left_out_and_named(self):
        glm = {'runtime_model_id': 'registered_glm53_flash', 'artifact_sha256': OTHER}
        self.catalog(self.entry('Qwen3.5-9B', 'v2/q/r1'), {'id': 'no-prefix', 'aggregate_sha256': OTHER}, 'not an entry')
        found, skipped, failures = self.fetch(self.listed + [glm])
        self.assertEqual((skipped, failures), ([glm], []))
        self.assertEqual(len(found[ARTIFACT]), 2)
        self.assertNotIn(OTHER, found)
        # Nothing of the absent model is asked for.
        self.assertFalse(any('no-prefix' in path for path, _ in Registry.hits))

    def test_model_ids_and_prefixes_are_escaped_as_the_provider_escapes_them(self):
        self.assertEqual(MODELS.model_id_path('EigenLabs/Qwen3.8 27B'), 'EigenLabs%2FQwen3.8%2027B')
        self.assertEqual(MODELS.r2_path('v2/A b/r1'), 'v2/A%20b/r1')
        self.catalog(self.entry('EigenLabs/Qwen3.8-27B', 'v2/Qwen3.8--x/r1'))
        found, _, _ = self.fetch()
        self.assertEqual(len(found[ARTIFACT]), 2)
        self.assertIn(('/dev/v1/models/catalog/manifest/EigenLabs%2FQwen3.8-27B', MODELS.USER_AGENT), Registry.hits)

    def test_a_manifest_that_does_not_match_is_never_a_candidate(self):
        config = CONFIG
        rows = {
            'another model': manifest('Other'),
            'another aggregate': manifest('Qwen3.5-9B', aggregate=OTHER),
            'no config.json': manifest('Qwen3.5-9B', files=[{'path': 'a', 'size_bytes': 1, 'sha256': 'c' * 64}]),
            'config.json twice': manifest('Qwen3.5-9B', files=[
                {'path': 'config.json', 'size_bytes': len(config), 'sha256': hashlib.sha256(config).hexdigest()}] * 2),
            'config size not an integer': manifest('Qwen3.5-9B', files=[
                {'path': 'config.json', 'size_bytes': '25', 'sha256': hashlib.sha256(config).hexdigest()}]),
            'config size a boolean': manifest('Qwen3.5-9B', files=[
                {'path': 'config.json', 'size_bytes': True, 'sha256': hashlib.sha256(config).hexdigest()}]),
            'config digest malformed': manifest('Qwen3.5-9B', files=[
                {'path': 'config.json', 'size_bytes': len(config), 'sha256': 'X' * 64}]),
            'config size differs': manifest('Qwen3.5-9B', config=config + b' '),
            'config digest differs': manifest('Qwen3.5-9B', files=[
                {'path': 'config.json', 'size_bytes': len(config), 'sha256': 'd' * 64}]),
            'not JSON': b'{',
            'not an object': b'[]',
        }
        for label, body in rows.items():
            with self.subTest(row=label):
                Registry.routes = {}
                self.catalog(self.entry('Qwen3.5-9B', 'v2/q/r1', cdn=body, coordinator=body))
                found, skipped, failures = self.fetch()
                self.assertEqual((found[ARTIFACT], skipped), ([], []))
                self.assertEqual(len(failures), 1)
                self.assertTrue(failures[0].startswith(f'Qwen3.5-9B (registered_qwen35_9b, {ARTIFACT}): '))

    def test_every_catalog_entry_of_a_listed_artifact_needs_a_usable_manifest(self):
        # One entry of the artifact answers, the other does not: the second fails by name.
        good = self.entry('Qwen3.5-9B', 'v2/q/r1')
        self.catalog(good, {'id': 'Qwen3.5-9B-copy', 'r2_prefix': 'v2/copy/r1', 'aggregate_sha256': ARTIFACT})
        found, _, failures = self.fetch()
        self.assertEqual(len(found[ARTIFACT]), 2)
        self.assertEqual(len(failures), 1)
        self.assertTrue(failures[0].startswith('Qwen3.5-9B-copy (registered_qwen35_9b, '))
        self.assertIn('HTTP 404', failures[0])

    def test_server_errors_are_retried_and_client_errors_are_not(self):
        url = self.base + '/flaky'
        Registry.routes['/flaky'] = [(503, b'', {}), (200, b'ok', {})]
        self.assertEqual(MODELS.get(url, 10), b'ok')
        Registry.routes['/down'] = [(500, b'', {})]
        with self.assertRaisesRegex(MODELS.FetchError, 'HTTP 500'):
            MODELS.get(self.base + '/down', 10)
        self.assertEqual(sum(path == '/down' for path, _ in Registry.hits), MODELS.ATTEMPTS)
        with self.assertRaisesRegex(MODELS.FetchError, 'HTTP 404'):
            MODELS.get(self.base + '/missing', 10)
        self.assertEqual(sum(path == '/missing' for path, _ in Registry.hits), 1)

    def test_redirects_oversize_bodies_and_unreachable_hosts_are_refused(self):
        self.route('/moved', b'', status=302, headers={'Location': self.base + '/elsewhere'})
        with self.assertRaisesRegex(MODELS.FetchError, 'redirect'):
            MODELS.get(self.base + '/moved', 10)
        self.route('/large', b'x' * 11)
        with self.assertRaisesRegex(MODELS.FetchError, 'more than 10 bytes'):
            MODELS.get(self.base + '/large', 10)
        closed = http.server.HTTPServer(('127.0.0.1', 0), Registry)
        port = closed.server_address[1]
        closed.server_close()
        with self.assertRaises(MODELS.FetchError):
            MODELS.get(f'http://127.0.0.1:{port}/', 10)
        self.assertEqual(self.sleeps.call_count, MODELS.ATTEMPTS - 1)

    def test_an_unreadable_or_unreachable_catalog_stops_the_fetch(self):
        for body in (b'{', b'{"models": {}}', b'[]'):
            with self.subTest(body=body):
                self.route('/dev/v1/models/catalog', body)
                with self.assertRaisesRegex(MODELS.FetchError, 'unreadable model catalog'):
                    self.fetch()
        Registry.routes = {}
        with self.assertRaisesRegex(MODELS.FetchError, 'HTTP 404'):
            self.fetch()

    def test_the_model_list_is_checked(self):
        for listed in ([], {}, [{'runtime_model_id': 'x'}],
                       [{'runtime_model_id': 'x', 'artifact_sha256': 'A' * 64}],
                       [{'runtime_model_id': 1, 'artifact_sha256': ARTIFACT}],
                       [{'runtime_model_id': 'x', 'artifact_sha256': ARTIFACT, 'extra': 1}]):
            with self.subTest(listed=listed):
                path = self.root / 'list.json'
                path.write_text(json.dumps(listed))
                with self.assertRaisesRegex(ValueError, 'release model list'):
                    MODELS.read_list(path)

    def test_each_environment_reads_its_own_catalog_and_cdn(self):
        self.assertEqual(MODELS.registry('dev'), ('https://api.dev.darkbloom.dev', 'https://models.darkbloom.ai'))
        self.assertEqual(MODELS.registry('staging'), ('https://api.staging.darkbloom.dev', 'https://models.darkbloom.ai'))
        self.assertEqual(MODELS.registry('prod'), ('https://api.darkbloom.dev', 'https://models.darkbloom.ai'))
        identity = self.root / 'identity.json'
        identity.write_text(json.dumps({'environments': {'dev': {'coordinatorHTTPURL': 'https://one/',
                                                                 'modelCDNURL': 'https://cdn/'}}}))
        self.assertEqual(MODELS.registry('dev', identity), ('https://one', 'https://cdn'))
        with self.assertRaisesRegex(ValueError, 'Unknown environment'):
            MODELS.registry('local')

    def test_main_writes_candidates_and_the_left_out_models_or_fails_without_writing(self):
        self.catalog(self.entry('Qwen3.5-9B', 'v2/q/r1'))
        listed = self.root / 'list.json'
        absent = {'runtime_model_id': 'registered_glm53_flash', 'artifact_sha256': OTHER}
        listed.write_text(json.dumps(self.listed + [absent]))
        output, skipped = self.root / 'candidates', self.root / 'skipped.md'
        arguments = ['--environment', 'dev', '--models', str(listed), '--output', str(output), '--skipped', str(skipped)]
        with patch.object(MODELS, 'registry', return_value=(self.coordinator, self.cdn)) as registry, \
                patch('sys.stdout') as stdout:
            self.assertEqual(MODELS.main(arguments), 0)
        registry.assert_called_once_with('dev')
        self.assertEqual(sorted(p.name for p in output.iterdir()), ['000', '001'])
        for folder in output.iterdir():
            self.assertEqual((folder / 'config.json').read_bytes(), CONFIG)
            self.assertEqual(json.loads((folder / 'manifest.json').read_bytes())['aggregate_sha256'], ARTIFACT)
        line = f'- Not in the dev catalog, left out: registered_glm53_flash (artifact {OTHER})\n'
        self.assertEqual(skipped.read_text(), line)
        self.assertIn(line.strip(), ''.join(call.args[0] for call in stdout.write.call_args_list))
        # A failure writes neither folder nor list.
        Registry.routes = {}
        self.catalog({'id': 'Qwen3.5-9B', 'r2_prefix': 'v2/q/r1', 'aggregate_sha256': ARTIFACT})
        refused = ['--environment', 'dev', '--models', str(listed), '--output', str(self.root / 'refused'),
                   '--skipped', str(self.root / 'refused.md')]
        with patch.object(MODELS, 'registry', return_value=(self.coordinator, self.cdn)), patch('sys.stderr') as stderr:
            self.assertEqual(MODELS.main(refused), 1)
        self.assertFalse((self.root / 'refused').exists())
        self.assertFalse((self.root / 'refused.md').exists())
        self.assertIn('Qwen3.5-9B (registered_qwen35_9b', ''.join(call.args[0] for call in stderr.write.call_args_list))


if __name__ == '__main__':
    unittest.main()
