"""Explicit nonproduction CLI transport; no ambient API URL or credential logs."""
import ipaddress
import json
import os
from pathlib import Path
from urllib.parse import urlsplit
import uuid

from sandbox_ci_bundle import digest, write_json
from sandbox_ci_capture import capture

PRODUCTION_HOSTS = {'api.darkbloom.dev', 'api.darkbloom.ai', 'darkbloom.ai', 'www.darkbloom.ai'}


def redact(value, secret):
    if isinstance(value, str):
        return value.replace(secret, '[REDACTED]')
    if isinstance(value, list):
        return [redact(item, secret) for item in value]
    if isinstance(value, dict):
        return {redact(key, secret): redact(item, secret) for key, item in value.items()}
    return value


def safe_output(data, secret):
    text = data.decode('utf-8', errors='replace')
    try:
        # Decode valid JSON first so escaped credentials cannot bypass masking.
        parsed = json.loads(text)
        sanitized = redact(parsed, secret)
        return text if sanitized == parsed else json.dumps(sanitized)
    except ValueError:
        return text.replace(secret, '[REDACTED]').replace(json.dumps(secret)[1:-1], '[REDACTED]')


def validate_nonproduction_url(value, allow_local):
    parsed = urlsplit(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/') or not parsed.hostname:
        raise ValueError('--api-url must be an explicit origin without credentials or path')
    hostname = parsed.hostname.lower().rstrip('.')
    if hostname in PRODUCTION_HOSTS:
        raise ValueError('production coordinators are not allowed by this benchmark')
    if parsed.scheme == 'https':
        return value.rstrip('/')
    try:
        loopback = ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        loopback = hostname == 'localhost'
    if parsed.scheme != 'http' or not allow_local or not loopback:
        raise ValueError('HTTPS required except explicit loopback opt-in')
    return value.rstrip('/')


class Remote:
    def __init__(self, cli, api_url, sandbox, output, allow_local):
        self.command = [str(cli), '--json', '--api-url', validate_nonproduction_url(api_url, allow_local)]
        if allow_local:
            self.command.append('--allow-insecure-localhost')
        self.sandbox = str(sandbox)
        self.root = 'ci-benchmark-' + uuid.uuid4().hex
        self.output = output
        self.sequence = 0
        self.environment = {'PATH': '/usr/bin:/bin', 'HOME': str(output / 'private-home'),
                            'DARKBLOOM_API_KEY': os.environ.get('DARKBLOOM_API_KEY', '')}
        (output / 'private-home').mkdir(mode=0o700)
        if not self.environment['DARKBLOOM_API_KEY']:
            raise ValueError('DARKBLOOM_API_KEY is required for paired measurements')

    def call(self, arguments, timeout=960, allow_failure=False):
        result = capture(self.command + [str(arg) for arg in arguments], env=self.environment, timeout=timeout)
        wall = result['wall_seconds']
        self.sequence += 1
        # CLI stderr may include caller-selected command labels. Credentials are
        # never written, even if a failing transport echoes an environment key.
        secret = self.environment['DARKBLOOM_API_KEY']
        raw = redact({'argv': [str(arg) for arg in arguments], 'exit_code': result['returncode'], 'wall_seconds': wall,
                      'interrupted': result['interrupted'], 'capture_truncated': result['capture_truncated'],
                      'stdout': safe_output(result['stdout'], secret), 'stderr': safe_output(result['stderr'], secret)}, secret)
        write_json(self.output / f'cli-{self.sequence:04}.json', raw)
        if result['interruption_error'] is not None:
            raise result['interruption_error']
        if result['interrupted'] or result['capture_truncated'] or (result['returncode'] and not allow_failure):
            raise RuntimeError(f'consumer CLI step failed; see cli-{self.sequence:04}.json')
        payload = json.loads(result['stdout'])
        if not isinstance(payload, dict):
            raise ValueError('consumer CLI response must be a JSON object')
        return payload, wall

    def execute(self, arguments, allow_failure=False):
        job, wall = self.call(['exec', '--timeout', '900', self.sandbox, '--', *arguments], allow_failure=allow_failure)
        accepted_states = ('succeeded', 'failed') if allow_failure else ('succeeded',)
        if job.get('state') not in accepted_states or (not allow_failure and job.get('exit_code') != 0) or job.get('output_truncated') or job.get('cancellation_pending'):
            raise RuntimeError('guest CI runner did not complete successfully')
        if not isinstance(job.get('stdout'), str) or not isinstance(job.get('id'), str):
            raise ValueError('guest CI command result is incomplete')
        if str(uuid.UUID(job['id'])) != job['id']:
            raise ValueError('guest CI command identity is invalid')
        result = json.loads(job['stdout'])
        if not isinstance(result, dict):
            raise ValueError('guest CI runner result must be a JSON object')
        return result, wall, job['id']

    def upload_bundle(self, bundle, manifest_hash):
        inspected, _ = self.call(['inspect', self.sandbox])
        if inspected.get('state') != 'ready':
            raise ValueError('benchmark requires an explicitly selected ready sandbox')
        manifest = json.loads((bundle / 'manifest.json').read_text())
        if inspected.get('cpu_count', 0) < manifest['gomaxprocs']:
            raise ValueError('sandbox CPU allocation is smaller than requested GOMAXPROCS')
        self.call(['mkdir', self.sandbox, self.root])
        for name in ('runner', 'go-sdk.tar.gz', 'source.tar.gz', 'manifest.json'):
            uploaded, _ = self.call(['upload', self.sandbox, bundle / name, self.root + '/' + name])
            if uploaded.get('state') != 'committed' or uploaded.get('sha256') != digest(bundle / name):
                raise ValueError('uploaded CI bundle content identity mismatch')
        job, _ = self.call(['exec', '--timeout', '60', self.sandbox, '--', '/bin/chmod', '700', '/workspace/' + self.root + '/runner'])
        if job.get('state') != 'succeeded' or job.get('exit_code') != 0:
            raise RuntimeError('runner executable permission setup failed')
        prepared, _, _ = self.execute(['/workspace/' + self.root + '/runner', 'prepare', '--root', '/workspace/' + self.root, '--manifest-sha256', manifest_hash])
        if prepared.get('status') != 'prepared' or prepared.get('manifest_sha256') != manifest_hash:
            raise ValueError('guest bundle preparation proof mismatch')
        return inspected

    def sample(self, manifest_hash, run_id, timeout):
        sample, wall, command_id = self.execute(['/workspace/' + self.root + '/runner', 'run', '--root', '/workspace/' + self.root,
                                               '--manifest-sha256', manifest_hash, '--run-id', run_id, '--timeout-seconds', timeout], allow_failure=True)
        expected_path = f'runs/{run_id}/evidence.tar.gz'
        if sample.get('evidence_path') != expected_path:
            raise ValueError('guest returned unexpected evidence path')
        destination = self.output / (run_id + '-guest-evidence.tar.gz')
        self.call(['download', self.sandbox, self.root + '/' + expected_path, destination])
        if digest(destination) != sample.get('evidence_sha256'):
            raise ValueError('downloaded guest evidence digest mismatch')
        sample.update(caller_wall_seconds=wall, command_id=command_id, downloaded_evidence=str(destination))
        return sample
