#!/usr/bin/env python3
"""Stage immutable signed products, then publish the same bytes after approval.

Signing and publication are separate jobs. Rerunning publication never signs or
rebuilds. The release key can request promotion, but cannot grant qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request

from provider_release_github import publish_github_release
from provider_release_ops.evidence import evidence
from provider_release_ops.resume import resume_source
from provider_release_ops.summary import summary as qualification_summary
from provider_release_ops.verification import verify_publication

BUNDLE = 'darkbloom-bundle-macos-arm64.tar.gz'
# Cloudflare in front of r2.dev answers the default Python-urllib User-Agent
# with 403 (error code 1010); every release request names itself instead.
USER_AGENT = 'darkbloom-provider-release/1 (+https://github.com/Layr-Labs/d-inference)'


class ReadinessPending(RuntimeError):
    pass


class CoordinatorUnreachable(ReadinessPending):
    """No HTTP answer at all. `await` keeps polling; the one-shot publish gate
    defers to registration, which enforces qualification itself."""


class QualificationTimeout(RuntimeError):
    pass


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def object_key(payload):
    return f"releases/v{payload['version']}/artifacts/{payload['bundle_hash']}/{BUNDLE}"


def validate(payload, env):
    if env["ENV_PREFIX"] not in {"dev", "prod"}:
        raise ValueError("Unknown publication environment")
    # source_commit/ci_run_id bind to SOURCE_SHA/SOURCE_RUN_ID when set (a
    # resumed publish run), else to this run's own GITHUB_SHA/GITHUB_RUN_ID.
    # prepare() always writes GITHUB_SHA/GITHUB_RUN_ID directly: signing only
    # happens in the source run, so there is nothing to resume there.
    expected = {'version': env['VERSION'], 'source_commit': env.get('SOURCE_SHA') or env['GITHUB_SHA'],
                'ci_run_id': env.get('SOURCE_RUN_ID') or env['GITHUB_RUN_ID'], 'platform': 'macos-arm64',
                'backend': 'mlx-swift', 'require_app_attest_qualification': env['ENV_PREFIX'] == 'prod'}
    for key, value in expected.items():
        if payload.get(key) != value:
            raise ValueError(f'Publication identity mismatch: {key}')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?', payload['version']):
        raise ValueError('Invalid release version')
    for key in ['binary_hash', 'bundle_hash', 'metallib_hash', 'code_directory_hash']:
        if not re.fullmatch('[0-9a-f]{64}', payload.get(key, '')):
            raise ValueError(f'Invalid signed digest: {key}')
    if payload['url'] != env['R2_PUBLIC_URL'].rstrip('/') + '/' + object_key(payload):
        raise ValueError('Publication origin or immutable object path changed')


def release_changelog(env):
    if env.get('GITHUB_REF_TYPE') == 'tag':
        # Read annotation text as data: never interpolate it into Python or a
        # shell program. Preserve multiline notes in the retained JSON payload.
        result = subprocess.run(['git', 'tag', '--list', '--format=%(contents)',
                                 '--', env['GITHUB_REF_NAME']], capture_output=True, text=True, check=True)
        if result.stdout.strip():
            return result.stdout.strip()
    return f"Release v{env['VERSION']}"


def prepare(root, bundle, env):
    root.mkdir(parents=True, exist_ok=False)
    payload = {
        'version': env['VERSION'], 'platform': 'macos-arm64', 'backend': 'mlx-swift',
        'binary_hash': env['BINARY_HASH'], 'bundle_hash': env['BUNDLE_HASH'],
        'metallib_hash': env['METALLIB_HASH'], 'code_directory_hash': env['CODE_DIRECTORY_HASH'],
        'source_commit': env['GITHUB_SHA'], 'ci_run_id': env['GITHUB_RUN_ID'],
        'require_app_attest_qualification': env['ENV_PREFIX'] == 'prod',
        'changelog': release_changelog(env),
    }
    payload['url'] = env['R2_PUBLIC_URL'].rstrip('/') + '/' + object_key(payload)
    validate(payload, env)
    if sha256(bundle) != payload['bundle_hash']:
        raise ValueError('Signed bundle changed after final verification')
    shutil.copyfile(bundle, root / BUNDLE)
    (root / 'release-payload.json').write_text(json.dumps(payload, indent=2) + '\n')
    qualification = {k: payload[k] for k in ['code_directory_hash', 'source_commit', 'ci_run_id']}
    qualification['release'] = {k: v for k, v in payload.items() if k not in qualification and k != 'require_app_attest_qualification'}
    qualification['evidence'] = ''  # Operator supplies actual test evidence, never CI-invented approval.
    (root / 'qualification-request.json').write_text(json.dumps(qualification, indent=2) + '\n')
    notes = f"""## Provider v{payload['version']} (Swift CLI)

**Source:** https://github.com/{env['GITHUB_REPOSITORY']}/commit/{payload['source_commit']}
**Build:** https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{payload['ci_run_id']}
**Binary SHA-256:** `{payload['binary_hash']}`
**CodeDirectory SHA-256:** `{payload['code_directory_hash']}`
**Bundle SHA-256:** `{payload['bundle_hash']}`
**Metallib SHA-256:** `{payload['metallib_hash']}`
**Signed and notarized:** yes
**Minimum macOS:** 14.0

### Install

```bash
curl -fsSL {env['COORDINATOR_URL'].rstrip('/')}/install.sh | bash
```
"""
    (root / 'release-notes.md').write_text(notes)
    return payload


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Refusing a redirected coordinator request')


def coordinator(env, path, payload=None):
    headers = {'Accept': 'application/json', 'User-Agent': USER_AGENT}
    data = None
    if payload is not None:
        headers.update({'Content-Type': 'application/json', 'Authorization': 'Bearer ' + env['RELEASE_KEY']})
        data = json.dumps(payload).encode()
    request = urllib.request.Request(env['COORDINATOR_URL'].rstrip('/') + path, data=data, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=150) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 503 and payload is None:
            raise ReadinessPending('Coordinator download policy is still converging') from exc
        if exc.code == 409:
            raise RuntimeError('Publication blocked: approve qualification-request.json with test evidence '
                               'via POST /v1/admin/app-attest/builds, then rerun ONLY the failed publication job. '
                               'Do not rerun signing; it creates different signed bytes.') from exc
        raise RuntimeError(f'Coordinator refused publication/readiness (HTTP {exc.code}); no latest aliases advanced') from exc


def qualification_status(env, payload):
    """POST /v1/releases/qualification and classify the response.

    A dedicated request path, separate from
    coordinator(): coordinator()'s 503-means-retry mapping only applies when
    payload is None (a GET), so registration (POST /v1/releases, always a
    payload) never gets treated as retryable there. 404/405 (coordinator build
    predates this endpoint) and any coordinator this client cannot even reach
    both become the 'unsupported' sentinel: POST /v1/releases enforces
    qualification itself (its own 409), so a stale/unreachable status endpoint
    must not block a release outright. A 503 raises ReadinessPending so
    `await` can retry it; a successful response is returned untouched.
    """
    headers = {'Accept': 'application/json', 'Content-Type': 'application/json', 'User-Agent': USER_AGENT,
               'Authorization': 'Bearer ' + env['RELEASE_KEY']}
    request = urllib.request.Request(env['COORDINATOR_URL'].rstrip('/') + '/v1/releases/qualification',
                                      data=json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=150) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 405):
            return {'status': 'unsupported'}
        if exc.code == 503:
            raise ReadinessPending('Coordinator qualification status is still converging') from exc
        raise RuntimeError(f'Coordinator refused qualification status (HTTP {exc.code})') from exc
    except urllib.error.URLError as exc:
        raise CoordinatorUnreachable(f'Coordinator unreachable for qualification status: {exc.reason}') from exc


def _not_required(payload, result):
    # Only production payloads require App Attest qualification at registration
    # (release_handlers.go persistReleaseForPublication). A dev publication with
    # no approval row must not wait for an approval nobody will give.
    return result.get('status') == 'pending' and not payload.get('require_app_attest_qualification')


MAX_WAIT_MINUTES = 75  # publish-release timeout-minutes (90) minus registration headroom


def _qualification_message(result):
    status_value = result.get('status')
    if status_value == 'revoked':
        return (f"qualification revoked by {result.get('revoked_by', '?')} at "
                f"{result.get('revoked_at', '?')}: {result.get('revocation_reason', '?')}")
    if status_value == 'mismatched':
        return 'qualification mismatched fields: ' + ', '.join(result.get('mismatched_fields', []))
    if status_value == 'pending':
        return 'qualification is still pending'
    return f'qualification status: {status_value}'


_GATE_BLOCKING_STATUSES = {'pending', 'revoked', 'mismatched'}


def qualification_gate(env, payload):
    """One status check without waiting. Blocks only on
    a status the coordinator explicitly reports as not-ready or refused;
    approved/unsupported/anything else this client cannot classify defers to
    registration's own enforcement."""
    try:
        result = qualification_status(env, payload)
    except CoordinatorUnreachable:
        return {'status': 'unsupported'}
    if _not_required(payload, result):
        return {'status': 'not_required'}
    if result.get('status') in _GATE_BLOCKING_STATUSES:
        raise RuntimeError('Publication blocked before registration: ' + _qualification_message(result))
    return result


_STATUS_EXIT_CODES = {'approved': 0, 'pending': 3, 'revoked': 4, 'mismatched': 5, 'unsupported': 6}


def status(root, env):
    payload = checked_payload(root, env)
    try:
        result = qualification_status(env, payload)
    except ReadinessPending as exc:
        print(json.dumps({'status': 'unavailable', 'detail': str(exc)}))
        return 1
    print(json.dumps(result))
    return _STATUS_EXIT_CODES.get(result.get('status'), 1)


def _append_approved_summary(env, result):
    step_summary = env.get('GITHUB_STEP_SUMMARY')
    if not step_summary:
        return
    with open(step_summary, 'a') as fh:
        fh.write('\n## Independent build qualification approved\n\n')
        fh.write(f"- approved_by: {result.get('approved_by', '')}\n")
        fh.write(f"- approved_at: {result.get('approved_at', '')}\n\n")
        fh.write('```\n' + result.get('evidence', '') + '\n```\n')


def await_qualification(root, env):
    payload = checked_payload(root, env)
    poll_seconds = float(env.get('QUALIFICATION_POLL_SECONDS', 30))
    window_minutes = float(env.get('QUALIFICATION_WAIT_MINUTES') or 60)
    if window_minutes > MAX_WAIT_MINUTES:
        print(f'::warning::QUALIFICATION_WAIT_MINUTES={window_minutes:g} exceeds the job timeout; using {MAX_WAIT_MINUTES}')
        window_minutes = MAX_WAIT_MINUTES
    window_seconds = window_minutes * 60
    start = time.monotonic()
    binary = payload['binary_hash']
    while True:
        try:
            result = qualification_status(env, payload)
        except ReadinessPending:
            result = {'status': 'pending'}
        status_value = result.get('status')
        if _not_required(payload, result):
            print('::notice::This payload does not require App Attest qualification; continuing to registration')
            return {'status': 'not_required'}
        if status_value == 'approved':
            _append_approved_summary(env, result)
            return result
        if status_value == 'unsupported':
            print(f'::warning::Coordinator reports no build qualification status for binary '
                  f'{binary[:12]}...; registration will still enforce it')
            return result
        if status_value in ('revoked', 'mismatched'):
            raise RuntimeError(_qualification_message(result))
        elapsed = time.monotonic() - start
        print(f'qualification pending for binary {binary[:12]}... '
              f'(elapsed {int(elapsed)}s / window {int(window_seconds)}s)')
        if elapsed >= window_seconds:
            raise QualificationTimeout(
                'qualification timeout waiting for independent build qualification '
                f'(binary {binary[:12]}...); rerun failed jobs after approval; do not rerun signing')
        time.sleep(min(poll_seconds, max(window_seconds - elapsed, 0)))


def upload(root, key, env):
    subprocess.run(['aws', 's3', 'cp', str(root / BUNDLE), f"s3://{env['R2_BUCKET']}/{key}",
                    '--endpoint-url', env['R2_ENDPOINT'], '--only-show-errors'], check=True)


def checked_payload(root, env):
    payload = json.loads((root / 'release-payload.json').read_text())
    validate(payload, env)
    if sha256(root / BUNDLE) != payload['bundle_hash']:
        raise ValueError('Staged signed bundle digest mismatch')
    return payload


def stage(root, env):
    payload = checked_payload(root, env)
    upload(root, object_key(payload), env)


def core(version):
    match = re.match(r'^(\d+)\.(\d+)\.(\d+)', version)
    if match is None:
        raise ValueError('Malformed latest release version')
    return tuple(int(v) for v in match.groups())


def await_latest(env, payload):
    # A different coordinator may still have the previous five-second policy
    # snapshot. An older response must not silently skip promotion of this build.
    for attempt in range(7):
        try:
            latest = coordinator(env, '/v1/releases/latest?platform=macos-arm64')
            if latest.get('version') == payload['version']:
                if latest.get('bundle_hash') != payload['bundle_hash']:
                    raise ValueError('Published version contains different signed bytes')
                return True
            if core(latest.get('version', '')) > core(payload['version']):
                return False
        except ReadinessPending:
            # A 503 is expected while another coordinator loads the committed
            # policy. Retry within the same bounded convergence window.
            pass
        if attempt < 6:
            time.sleep(2)
    raise RuntimeError('Latest release readiness has not converged; rerun the publication job')


def publish(root, env):
    payload = checked_payload(root, env)
    gate = qualification_gate(env, payload)
    coordinator(env, '/v1/releases', payload)
    # Confirm serving policy is active before public aliases/GitHub publication.
    # An older concurrently staged release must never roll latest aliases back.
    is_latest = await_latest(env, payload)
    if is_latest:
        for name in [BUNDLE, 'eigeninference-bundle-macos-arm64.tar.gz']:
            upload(root, 'releases/latest/' + name, env)
    if env['ENV_PREFIX'] == 'prod':
        note = gate.get('evidence') if gate.get('status') == 'approved' else None
        publish_github_release(root, BUNDLE, payload['bundle_hash'], env, is_latest,
                                qualification_evidence=note or 'Qualification record unavailable from coordinator')


def _download_sha256(url):
    hasher = hashlib.sha256()
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=150) as response:
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def verify(root, env):
    return verify_publication(root, env, coordinator=coordinator, core=core,
                              object_key=object_key, download_sha256=_download_sha256,
                              bundle_name=BUNDLE)


def summary(root, env):
    return qualification_summary(root, env, BUNDLE)


OPERATIONS = {'stage': stage, 'publish': publish, 'summary': summary, 'await': await_qualification, 'verify': verify}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'stage', 'publish', 'status', 'await',
                                               'summary', 'evidence', 'resume-source', 'verify'])
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--result', action='append', default=[])
    parser.add_argument('--exception', action='append', default=[])
    parser.add_argument('--operator')
    parser.add_argument('--run-id')
    args = parser.parse_args()
    if args.operation == 'resume-source':
        if args.run_id is None:
            parser.error('resume-source requires --run-id')
        resume_source(os.environ, args.run_id)
        return
    if args.directory is None:
        parser.error(args.operation + ' requires --directory')
    if args.operation == 'prepare':
        if args.bundle is None:
            parser.error('prepare requires --bundle')
        prepare(args.directory, args.bundle, os.environ)
    elif args.operation == 'status':
        raise SystemExit(status(args.directory, os.environ))
    elif args.operation == 'evidence':
        evidence(args.directory, args.result, args.exception, args.operator)
    else:
        OPERATIONS[args.operation](args.directory, os.environ)


if __name__ == '__main__':
    main()
