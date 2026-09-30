"""Combine exact-artifact check results and explicit operator exceptions."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re

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
    if overhead > 4096:
        raise ValueError('evidence: operator attribution and required check labels exceed 4096 bytes')
    budget = max(0, 4096 - overhead)
    per_exception = budget // len(exceptions) if exceptions else 0
    exception_lines = [template + _byte_truncate(exc['reason'], per_exception)
                        for exc, template in zip(exceptions, templates)]
    text = '\n'.join([header] + passed_lines + exception_lines + [results_line])
    # Defensive final clamp: the budget split above should already fit: this
    # only guards an edge case in the arithmetic, never the normal path.
    return _byte_truncate(text, 4096)


def evidence(root, result_paths, exception_specs, operator):
    if exception_specs and (not operator or not operator.strip()):
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
    if len(exceptions_by_key) != len(exceptions):
        raise ValueError('evidence: duplicate exception for the same lane and check')
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

