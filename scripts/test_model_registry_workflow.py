"""Exercise the actual workflow shell steps against an isolated HTTP server."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import threading
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/register-model.yml'
REGISTRATION_FIELDS = ('DISPLAY_NAME', 'QUANTIZATION', 'MAX_CONTEXT_LENGTH',
                       'MAX_OUTPUT_LENGTH', 'MIN_RAM_GB', 'INPUT_PRICE', 'OUTPUT_PRICE')


def input_block(name):
    """Read one dispatch input's settings without adding a YAML dependency."""
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index('      ' + name + ':') + 1
    stop = next(i for i in range(start, len(lines))
                if lines[i] and not lines[i].startswith('        '))
    return lines[start:stop]


def step(name):
    """Read a literal run block from this workflow's named step."""
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index('      - name: ' + name) + 1
    stop = next((i for i in range(start, len(lines)) if lines[i].startswith('      - ')), len(lines))
    block = lines[start:stop]
    run = block.index('        run: |')
    return textwrap.dedent('\n'.join(block[run + 1:])).strip()


@contextlib.contextmanager
def coordinator(status=200):
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers['Content-Length']))
            requests.append((self.path, json.loads(body), self.headers['Authorization']))
            self.send_response(status)
            self.end_headers()
            self.wfile.write(b'{"status":"fixture"}')

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', requests
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


class ModelRegistryWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('AWS_', 'R2_'))}
        self.env.update(
            NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost',
            MODEL_ID='example/model', VERSION='test-r1', DISPLAY_NAME='Fixture',
            FAMILY='fixture', ARCHITECTURE='fixture', QUANTIZATION='4bit',
            CAPABILITIES_CSV='chat, tools', REQUIRED_PROVIDER_CAPABILITIES='',
            MAX_CONTEXT_LENGTH='4096', MAX_OUTPUT_LENGTH='256', MIN_RAM_GB='24',
            DESCRIPTION='Fixture only', RUNTIME_PARAMETERS_JSON='{"temperature":0.5}',
            HUGGING_FACE_ARTIFACT_JSON=json.dumps({'repo_id': 'example/model', 'revision': 'a' * 40}),
            METADATA_JSON='{"preserve":true}', PROMOTE='true', INPUT_PRICE='80000',
            OUTPUT_PRICE='130000', CACHE_READ_PRICE='',
            MODEL_REGISTRY_PUBLISHING_KEY='fixture-key', PUBLISH_REVISION_ONLY='true',
        )

    def run_step(self, name):
        return subprocess.run(['bash', '-e', '-u', '-o', 'pipefail', '-c', step(name)],
                              cwd=self.scratch.name, env=self.env, capture_output=True,
                              text=True, timeout=15)

    def test_existing_upload_needs_only_coordinator_credentials(self):
        # A minimal dispatch supplies no registration-only metadata or prices.
        for name in REGISTRATION_FIELDS:
            self.env.pop(name)
        self.env['METADATA_JSON'] = 'not-json'
        with coordinator() as (url, requests):
            self.env['COORDINATOR_URL'] = url
            built = self.run_step('Build revision-only payload')
            self.assertEqual(built.returncode, 0, built.stderr)
            sent = self.run_step('Publish model with coordinator')
            self.assertEqual(sent.returncode, 0, sent.stderr)
        self.assertEqual(requests, [('/v1/admin/models/example%2Fmodel/publish-revision',
                                   {'version': 'test-r1', 'hugging_face_artifact': {
                                       'repo_id': 'example/model', 'revision': 'a' * 40}},
                                   'Bearer fixture-key')])

    def test_normal_registration_preserves_payload_and_endpoint(self):
        self.env['PUBLISH_REVISION_ONLY'] = 'false'
        with coordinator() as (url, requests):
            self.env['COORDINATOR_URL'] = url
            built = self.run_step('Build registration payload')
            self.assertEqual(built.returncode, 0, built.stderr)
            sent = self.run_step('Publish model with coordinator')
            self.assertEqual(sent.returncode, 0, sent.stderr)
        path, body, auth = requests[0]
        self.assertEqual(path, '/v1/admin/models/register')
        self.assertEqual(auth, 'Bearer fixture-key')
        self.assertEqual(body['model_id'], 'example/model')
        self.assertEqual(body['metadata'], {'preserve': True})
        self.assertEqual(body['capabilities'], ['chat', 'tools'])
        self.assertEqual((body['input_price'], body['output_price']), (80000, 130000))
        self.assertNotIn('cache_read_price', body)

    def test_registration_still_requires_metadata_limits_and_prices(self):
        original = self.env.copy()
        with coordinator() as (url, requests):
            for name in REGISTRATION_FIELDS:
                with self.subTest(missing=name):
                    self.env = dict(original, COORDINATOR_URL=url, **{name: ''})
                    self.assertNotEqual(self.run_step('Build registration payload').returncode, 0)
            for name in REGISTRATION_FIELDS[2:]:
                for value in ('0', '-1', '1.5'):
                    with self.subTest(field=name, invalid=value):
                        self.env = dict(original, COORDINATOR_URL=url, **{name: value})
                        self.assertNotEqual(self.run_step('Build registration payload').returncode, 0)
        self.assertEqual(requests, [])

    def test_dispatch_requires_only_model_and_version(self):
        for name in REGISTRATION_FIELDS:
            self.assertIn('        required: false', input_block(name.lower()), name)
        for name in ('model_id', 'version'):
            self.assertIn('        required: true', input_block(name), name)

    def test_revision_mode_requires_explicit_promotion(self):
        with coordinator() as (url, requests):
            for value in ('false', ''):
                with self.subTest(promote=value):
                    self.env.update(COORDINATOR_URL=url, PROMOTE=value)
                    result = self.run_step('Build revision-only payload')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('set promote=true', result.stderr)
        self.assertEqual(requests, [])

    def test_normal_registration_can_remain_unpromoted(self):
        self.env.update(PROMOTE='false', PUBLISH_REVISION_ONLY='false')
        with coordinator() as (url, requests):
            self.env['COORDINATOR_URL'] = url
            self.assertEqual(self.run_step('Build registration payload').returncode, 0)
            self.assertEqual(self.run_step('Publish model with coordinator').returncode, 0)
        self.assertFalse(requests[0][1]['promote'])

    def test_malformed_source_stops_before_publication(self):
        self.env['HUGGING_FACE_ARTIFACT_JSON'] = 'not-json'
        with coordinator() as (url, requests):
            self.env['COORDINATOR_URL'] = url
            self.assertNotEqual(self.run_step('Build revision-only payload').returncode, 0)
        self.assertEqual(requests, [])

    def test_http_failure_is_not_reported_as_success(self):
        with coordinator(503) as (url, requests):
            self.env['COORDINATOR_URL'] = url
            self.assertEqual(self.run_step('Build revision-only payload').returncode, 0)
            self.assertNotEqual(self.run_step('Publish model with coordinator').returncode, 0)
        self.assertEqual(len(requests), 1)

    def test_missing_publishing_key_never_posts(self):
        self.env['MODEL_REGISTRY_PUBLISHING_KEY'] = ''
        with coordinator() as (url, requests):
            self.env['COORDINATOR_URL'] = url
            self.assertEqual(self.run_step('Build revision-only payload').returncode, 0)
            self.assertNotEqual(self.run_step('Publish model with coordinator').returncode, 0)
        self.assertEqual(requests, [])

    def test_modes_stay_separate_without_storage_secrets(self):
        source = WORKFLOW.read_text()
        self.assertIn('if: ${{ !inputs.publish_revision_only }}', source)
        self.assertIn('if: ${{ inputs.publish_revision_only }}', source)
        self.assertNotIn('secrets.R2_', source)
        self.assertNotIn('AWS_ACCESS_KEY_ID', source)
        self.assertNotIn('prepare_bonsai_base', source)


if __name__ == '__main__':
    unittest.main()
