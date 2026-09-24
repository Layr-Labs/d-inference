#!/usr/bin/env python3
"""Stage immutable signed products, then publish the same bytes after approval.

Signing and publication are separate jobs. Rerunning publication never signs or
rebuilds. The release key can request promotion, but cannot grant qualification.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from provider_release_github import publish_github_release

BUNDLE = 'darkbloom-bundle-macos-arm64.tar.gz'


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
    headers = {'Accept': 'application/json'}
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

    A dedicated request path (CONTRACT.md #1177 C2), not a reuse/loosening of
    coordinator(): coordinator()'s 503-means-retry mapping only applies when
    payload is None (a GET), so registration (POST /v1/releases, always a
    payload) never gets treated as retryable there. 404/405 (coordinator build
    predates this endpoint) and any coordinator this client cannot even reach
    both become the 'unsupported' sentinel: POST /v1/releases enforces
    qualification itself (its own 409), so a stale/unreachable status endpoint
    must not block a release outright. A 503 raises ReadinessPending so
    `await` can retry it; a successful response is returned untouched.
    """
    headers = {'Accept': 'application/json', 'Content-Type': 'application/json',
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
    """One status check, no waiting (CONTRACT.md C2 `publish`). Blocks only on
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


# --- evidence (CONTRACT.md C4) ----------------------------------------------

LANES = ('macos-27', 'older-macos')
CHECK_STATES = ('passed', 'failed', 'not_run')
CONTROL_CHARS = re.compile(r'[\x00-\x1f\x7f]')
REQUIRED_STATIC = ['bundle-digest', 'binary-digest', 'metallib-digest', 'code-directory',
                   'codesign', 'notarization', 'team-id', 'minimum-macos', 'lane-host']
REQUIRED_SMOKE = ['version', 'runtime-smoke']
REQUIRED_LIVE = {'macos-27': ['app-attest', 'inference', 'graceful-drain', 'accounting'],
                  'older-macos': ['inference', 'graceful-drain', 'accounting']}
IDENTITY_KEYS = ('version', 'binary_hash', 'bundle_hash', 'metallib_hash',
                  'code_directory_hash', 'source_commit', 'ci_run_id')


def required_checks(lane):
    return REQUIRED_STATIC + REQUIRED_SMOKE + REQUIRED_LIVE[lane]


def _expected_identity(root):
    payload = json.loads((root / 'release-payload.json').read_text())
    request = json.loads((root / 'qualification-request.json').read_text())
    identity = {key: payload[key] for key in IDENTITY_KEYS}
    request_identity = {
        'version': request['release']['version'], 'binary_hash': request['release']['binary_hash'],
        'bundle_hash': request['release']['bundle_hash'], 'metallib_hash': request['release']['metallib_hash'],
        'code_directory_hash': request['code_directory_hash'], 'source_commit': request['source_commit'],
        'ci_run_id': request['ci_run_id'],
    }
    if request_identity != identity:
        raise ValueError('evidence: release-payload.json and qualification-request.json identity disagree')
    return identity


def _byte_truncate(text, limit):
    if limit <= 0:
        return ''
    data = text.encode()
    if len(data) <= limit:
        return text
    return data[:limit].decode('utf-8', 'ignore')


def _render_evidence(header, passed_lines, exceptions, results_line):
    fixed_bytes = sum(len(line.encode()) + 1 for line in [header] + passed_lines + [results_line])
    templates = [f"EXCEPTION {exc['lane']}:{exc['check']} NOT RUN by {exc['operator']}: " for exc in exceptions]
    overhead = fixed_bytes + sum(len(t.encode()) + 1 for t in templates)
    budget = max(0, 4096 - overhead)
    per_exception = budget // len(exceptions) if exceptions else 0
    exception_lines = [template + _byte_truncate(exc['reason'], per_exception)
                        for exc, template in zip(exceptions, templates)]
    text = '\n'.join([header] + passed_lines + exception_lines + [results_line])
    # Defensive final clamp: the budget split above should already fit: this
    # only guards an edge case in the arithmetic, never the normal path.
    return _byte_truncate(text, 4096)


def evidence(root, result_paths, exception_specs, operator):
    if exception_specs and not operator:
        raise ValueError('evidence: --operator is required when any --exception is given')
    identity = _expected_identity(root)

    results_by_lane = {}
    for path in result_paths:
        result = json.loads(Path(path).read_text())
        lane = result.get('lane')
        if lane not in LANES:
            raise ValueError(f'evidence: unknown lane in result: {lane!r}')
        if lane in results_by_lane:
            raise ValueError(f'evidence: duplicate result for lane {lane}')
        if result.get('identity') != identity:
            raise ValueError(f'evidence: identity mismatch in result for lane {lane}')
        # One entry per check, and only the three recorded states: a duplicate
        # could hide a failure behind a later pass, and an unknown state is
        # neither a pass nor something an operator excepted.
        names = [c.get('name') for c in result.get('checks', [])]
        if len(names) != len(set(names)):
            raise ValueError(f'evidence: duplicate check names in result for lane {lane}')
        for check in result.get('checks', []):
            if check.get('status') not in CHECK_STATES:
                raise ValueError(f"evidence: unknown status {check.get('status')!r} for {lane}:{check.get('name')}")
        results_by_lane[lane] = result

    exceptions = []
    for spec in exception_specs:
        key, sep, reason = spec.partition('=')
        if sep == '' or ':' not in key:
            raise ValueError(f'evidence: --exception must be lane:check=reason, got {spec!r}')
        lane, check = key.split(':', 1)
        # Evidence is line-oriented: a control character in operator text
        # could forge a PASSED line for a check that never ran.
        if (not reason.strip() or CONTROL_CHARS.search(reason) or CONTROL_CHARS.search(operator or '')
                or 'passed' in (reason + ' ' + (operator or '')).lower()):
            raise ValueError(f'evidence: exception reason and operator must be non-empty single-line text: {key}')
        exceptions.append({'lane': lane, 'check': check, 'reason': reason, 'operator': operator})
    exceptions_by_key = {(exc['lane'], exc['check']): exc for exc in exceptions}
    used_exceptions = set()

    for lane in LANES:
        result = results_by_lane.get(lane)
        statuses = {c['name']: c for c in result['checks']} if result else {}
        for check in required_checks(lane):
            entry = statuses.get(check)
            check_status = entry['status'] if entry else 'missing'
            if check_status == 'failed':
                # An exception cannot override a failure (C4): checked first,
                # unconditionally, before any exception lookup.
                raise ValueError(f'evidence: required check failed: {lane}:{check}')
            if check_status in ('not_run', 'missing'):
                exc_key = (lane, check)
                if exc_key not in exceptions_by_key:
                    raise ValueError(
                        f'evidence: required check {lane}:{check} is {check_status} and has no --exception')
                used_exceptions.add(exc_key)

    for exc in exceptions:
        exc_key = (exc['lane'], exc['check'])
        if exc_key in used_exceptions:
            continue
        if exc['lane'] not in results_by_lane or exc['check'] not in required_checks(exc['lane']):
            raise ValueError(f"evidence: exception names a check that is not required: {exc['lane']}:{exc['check']}")
        raise ValueError(f"evidence: exception names a check that passed: {exc['lane']}:{exc['check']}")

    payload = json.loads((root / 'release-payload.json').read_text())
    header = (f"darkbloom qualification v1 {payload['version']} "
              f"binary={payload['binary_hash'][:12]} cd={payload['code_directory_hash'][:12]} "
              f"run={payload['ci_run_id']}")
    passed_lines = []
    for lane in LANES:
        result = results_by_lane.get(lane)
        if result is None:
            continue
        statuses = {c['name']: c for c in result['checks']}
        passed = [c for c in required_checks(lane) if statuses.get(c, {}).get('status') == 'passed']
        host = result['host']
        passed_lines.append(f"PASSED {lane}: {','.join(passed)} (host {host['macos']} {host['model']})")

    evidence_doc = {
        'schema': 'darkbloom.provider-qualification-evidence/v1',
        'identity': identity,
        'results': [results_by_lane[lane] for lane in LANES if lane in results_by_lane],
        'exceptions': exceptions,
        'operator': operator,
        'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    }
    # RESULTS sha256 is computed over exactly the bytes written to
    # qualification-evidence.json: the file content IS this canonical
    # (sort_keys, minimal-separator) rendering, nothing excluded, so there is
    # no separate "canonical form" that could drift from what got hashed.
    canonical = json.dumps(evidence_doc, sort_keys=True, separators=(',', ':')).encode()
    results_line = 'RESULTS sha256=' + hashlib.sha256(canonical).hexdigest()
    text = _render_evidence(header, passed_lines, exceptions, results_line)

    request_path = root / 'qualification-request.json'
    request = json.loads(request_path.read_text())
    request['evidence'] = text

    # Only mutate once every refusal above has had the chance to raise, and
    # only via tmp+os.replace, so a crash mid-write cannot leave a torn file
    # and a refusal leaves qualification-request.json byte-identical.
    def atomic_write(path, data):
        tmp = path.with_name(path.name + '.tmp')
        tmp.write_bytes(data)
        os.replace(tmp, path)

    atomic_write(root / 'qualification-evidence.json', canonical)
    atomic_write(request_path, (json.dumps(request, indent=2) + '\n').encode())


# --- resume-source (CONTRACT.md C2) -----------------------------------------

def resume_source(env, run_id):
    repo = env['GITHUB_REPOSITORY']
    run_result = subprocess.run(['gh', 'api', f'repos/{repo}/actions/runs/{run_id}'],
                                 capture_output=True, text=True, check=True)
    run_info = json.loads(run_result.stdout)
    if run_info.get('path') != '.github/workflows/release-swift.yml':
        raise ValueError('resume-source: run does not belong to release-swift.yml')
    sha = env['GITHUB_SHA']
    if run_info.get('head_sha') != sha:
        raise ValueError('resume-source: run head_sha does not match GITHUB_SHA')

    # The repository is already pinned by the API path above, so a match here
    # implies the same repository; nothing else to cross-check on that axis.
    artifacts_result = subprocess.run(
        ['gh', 'api', f'repos/{repo}/actions/runs/{run_id}/artifacts', '--paginate'],
        capture_output=True, text=True, check=True)
    artifacts = json.loads(artifacts_result.stdout).get('artifacts', [])
    prefix = f'provider-publication-{sha}-'
    candidates = []
    for artifact in artifacts:
        name = artifact.get('name', '')
        if artifact.get('expired') or not name.startswith(prefix):
            continue
        suffix = name[len(prefix):]
        if suffix.isdigit():
            candidates.append((int(suffix), name))
    if not candidates:
        raise ValueError(f'resume-source: no non-expired publication artifact found for {sha}')
    _, artifact_name = max(candidates)

    with open(env['GITHUB_OUTPUT'], 'a') as fh:
        fh.write(f'source_run_id={run_id}\n')
        fh.write(f'source_sha={sha}\n')
        fh.write(f'publication_artifact={artifact_name}\n')


# --- verify (CONTRACT.md C2) -------------------------------------------------

def _download_sha256(url):
    hasher = hashlib.sha256()
    request = urllib.request.Request(url)
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=150) as response:
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def verify(root, env):
    payload = json.loads((root / 'release-payload.json').read_text())
    latest = coordinator(env, '/v1/releases/latest?platform=macos-arm64')
    is_latest = latest.get('version') == payload['version']
    # Only a strictly newer latest excuses the alias checks. An older latest is
    # the #1177 failure itself: the coordinator kept the previous release.
    superseded = not is_latest and core(latest.get('version') or '0.0.0') > core(payload['version'])

    surfaces = []

    def probe(name, fn):
        try:
            ok = bool(fn())
        except Exception:
            ok = False
        surfaces.append((name, ok))

    if is_latest:
        probe('registration (latest points at this version)',
              lambda: latest.get('bundle_hash') == payload['bundle_hash'])
    elif not superseded:
        probe(f"registration (latest is {latest.get('version')}, not {payload['version']})", lambda: False)
    else:
        print(f"note: latest is {latest.get('version')} (newer than {payload['version']}); "
              f"skipping releases/latest/* alias checks for this release")

    r2_base = env['R2_PUBLIC_URL'].rstrip('/')
    probe('immutable object', lambda: _download_sha256(r2_base + '/' + object_key(payload)) == payload['bundle_hash'])

    if is_latest:
        for name in [BUNDLE, 'eigeninference-bundle-macos-arm64.tar.gz']:
            surface = 'releases/latest/' + name
            probe(surface, lambda name=name: _download_sha256(r2_base + '/releases/latest/' + name) == payload['bundle_hash'])

    if env['ENV_PREFIX'] == 'prod':
        # publish creates the release under the pushed tag (provider_release_github.py).
        tag = env['GITHUB_REF_NAME'] if env.get('GITHUB_REF_TYPE') == 'tag' else 'v' + payload['version']
        repo = env['GITHUB_REPOSITORY']
        state = {}

        def not_a_draft():
            result = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo,
                                      '--json', 'isDraft,assets'], capture_output=True, text=True, check=True)
            state['release'] = json.loads(result.stdout)
            return not state['release']['isDraft']

        probe('github release not a draft', not_a_draft)

        def asset_matches():
            with tempfile.TemporaryDirectory(prefix='verify-release-') as directory:
                subprocess.run(['gh', 'release', 'download', tag, '--repo', repo,
                                 '--pattern', BUNDLE, '--dir', directory], check=True)
                with (Path(directory) / BUNDLE).open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            return digest == payload['bundle_hash']

        probe('github release asset', asset_matches)

    print('surface -> ok')
    for name, ok in surfaces:
        print(f'{name} -> {"ok" if ok else "MISMATCH"}')
    failed = [name for name, ok in surfaces if not ok]
    if failed:
        raise RuntimeError('verify: surface mismatch: ' + ', '.join(failed))


# --- summary (CONTRACT.md C2) ------------------------------------------------

def summary(root, env):
    payload = json.loads((root / 'release-payload.json').read_text())
    request_text = (root / 'qualification-request.json').read_text().strip()
    artifact_name = env.get('PUBLICATION_ARTIFACT') or BUNDLE
    # A resume run describes the run that signed these bytes, not itself.
    source_run = env.get('SOURCE_RUN_ID') or env['GITHUB_RUN_ID']
    source_sha = env.get('SOURCE_SHA') or env['GITHUB_SHA']
    run_url = f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{source_run}"

    lines = [
        '## Waiting for independent build qualification', '',
        f"Artifact `{artifact_name}` from source commit `{source_sha}`, "
        f"run [{source_run}]({run_url})"
        + ('' if env.get('SOURCE_RUN_ID', env['GITHUB_RUN_ID']) != env['GITHUB_RUN_ID']
           else f" attempt {env['GITHUB_RUN_ATTEMPT']}") + '.', '',
        '| digest | value |', '| --- | --- |',
        f"| binary | `{payload['binary_hash']}` |",
        f"| bundle | `{payload['bundle_hash']}` |",
        f"| metallib | `{payload['metallib_hash']}` |",
        f"| code directory | `{payload['code_directory_hash']}` |", '',
        '`qualification-request.json`:', '', '```json', request_text, '```', '',
        'Required checks (recorded once each lane validator uploads its result JSON):',
    ]
    for lane in LANES:
        for check in required_checks(lane):
            lines.append(f'- {lane}: `{check}` — not yet run')
    lines += [
        '', 'Run each lane validator against the retained publication directory:', '', '```bash',
        'python3 scripts/provider-release-qualify.py --directory <dir> --lane macos-27 '
        '--level static,smoke,live --output qualification-result-macos-27.json',
        'python3 scripts/provider-release-qualify.py --directory <dir> --lane older-macos '
        '--level static,smoke,live --output qualification-result-older-macos.json',
        '```', '', 'Render the operator evidence from both result files:', '', '```bash',
        'python3 scripts/provider-release-publication.py evidence --directory <dir> '
        '--result qualification-result-macos-27.json --result qualification-result-older-macos.json',
        '```', '', 'Submit the completed template for durable review recording (see '
        'docs/operations/app-attest-build-qualification.md step 3):', '', '```bash',
        'curl --fail-with-body --request POST "$COORDINATOR_URL/v1/admin/app-attest/builds" \\',
        '  --header "Authorization: Bearer $DARKBLOOM_ADMIN_TOKEN" \\',
        "  --header 'Content-Type: application/json' \\",
        '  --data-binary @qualification-request.json', '```',
    ]
    text = '\n'.join(lines) + '\n'

    step_summary = env.get('GITHUB_STEP_SUMMARY')
    if step_summary:
        with open(step_summary, 'a') as fh:
            fh.write(text)
    else:
        print(text)
    print('::notice::Publication staged; awaiting independent build qualification before registration')


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
