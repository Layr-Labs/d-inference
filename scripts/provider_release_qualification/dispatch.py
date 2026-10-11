#!/usr/bin/env python3
"""Dispatch trusted private qualification without downloading private source."""
from datetime import datetime, timedelta, timezone
import json
import os
import re
import secrets
import subprocess
import sys
import time
from urllib.parse import urlencode

PLATFORM_REPOSITORY = 'Layr-Labs/darkbloom-platform'
WORKFLOW_PATH = '.github/workflows/provider-release-qualification.yml'
WORKFLOW_API = f'repos/{PLATFORM_REPOSITORY}/actions/workflows/{WORKFLOW_PATH.rsplit("/", 1)[1]}'
TIMEOUT_SECONDS = 55 * 60
POLL_SECONDS = 15
REQUEST_FIELDS = frozenset({
    'environment', 'provider_run_id', 'provider_run_attempt', 'candidate_run_id',
    'candidate_artifact_id', 'candidate_artifact_digest', 'candidate_payload_sha256',
    'candidate_provenance_sha256', 'candidate_source_commit', 'static27', 'static26',
})


def text(value, pattern, label):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError('Invalid ' + label)
    return value


def positive(value, label):
    if type(value) is not int or value <= 0:
        raise ValueError('Invalid ' + label)
    return value


def artifact_digest(value):
    text(value, r'(?:sha256:)?[0-9a-f]{64}', 'artifact digest')
    return 'sha256:' + value.removeprefix('sha256:')


def validate_request(request):
    if not isinstance(request, dict) or set(request) != REQUEST_FIELDS:
        raise ValueError('Invalid qualification request fields')
    result = dict(request)
    if result['environment'] not in ('prod', 'dev'):
        raise ValueError('Invalid qualification environment')
    for key in ('provider_run_id', 'candidate_run_id', 'candidate_artifact_id'):
        text(result[key], r'[1-9][0-9]*', key)
    positive(result['provider_run_attempt'], 'provider run attempt')
    result['candidate_artifact_digest'] = artifact_digest(result['candidate_artifact_digest'])
    for key in ('candidate_payload_sha256', 'candidate_provenance_sha256'):
        text(result[key], r'[0-9a-f]{64}', key)
    text(result['candidate_source_commit'], r'[0-9a-f]{40}', 'candidate source commit')
    for key in ('static27', 'static26'):
        lane = result[key]
        if not isinstance(lane, dict) or set(lane) != {'artifact_id', 'artifact_digest', 'attempt'}:
            raise ValueError('Invalid ' + key + ' fields')
        result[key] = {
            'artifact_id': text(lane['artifact_id'], r'[1-9][0-9]*', key + ' artifact ID'),
            'artifact_digest': artifact_digest(lane['artifact_digest']),
            'attempt': positive(lane['attempt'], key + ' attempt'),
        }
        if result[key]['attempt'] > result['provider_run_attempt']:
            raise ValueError('Static report attempt exceeds provider workflow attempt')
    return result


def request_from_environment(environ):
    def attempt(key):
        return int(text(environ.get(key), r'[1-9][0-9]*', key))

    request = {
        'environment': environ.get('RELEASE_ENVIRONMENT'),
        'provider_run_id': environ.get('GITHUB_RUN_ID'),
        'provider_run_attempt': attempt('GITHUB_RUN_ATTEMPT'),
    }
    for field in ('run_id', 'artifact_id', 'artifact_digest', 'payload_sha256',
                  'provenance_sha256', 'source_commit'):
        request['candidate_' + field] = environ.get('RELEASE_CANDIDATE_' + field.upper())
    for major in (27, 26):
        prefix = f'RELEASE_STATIC{major}_'
        request[f'static{major}'] = {
            'artifact_id': environ.get(prefix + 'ARTIFACT_ID'),
            'artifact_digest': environ.get(prefix + 'ARTIFACT_DIGEST'),
            'attempt': attempt(prefix + 'ATTEMPT'),
        }
    return validate_request(request)


def validate_trust(ref, expected_sha):
    # Dispatch accepts a branch/tag name, not an immutable commit ID. Operators
    # protect this tag; checking the resulting run SHA detects a moved tag.
    text(ref, r'qualification/v[1-9][0-9]*', 'platform qualification tag')
    text(expected_sha, r'[0-9a-f]{40}', 'platform qualification SHA')


def github_api(method, path, payload=None, *, timeout=30):
    command = ['gh', 'api', '--hostname', 'github.com', '--method', method, path,
               '-H', 'Accept: application/vnd.github+json',
               '-H', 'X-GitHub-Api-Version: 2022-11-28']
    if payload is not None:
        command += ['--input', '-']
    try:
        completed = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                                   text=True, capture_output=True, check=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f'GitHub API {method} request failed') from exc
    return json.loads(completed.stdout) if completed.stdout.strip() else None


def validate_run(run, title, expected_sha, earliest, latest):
    if not isinstance(run, dict):
        raise ValueError('Invalid qualification run')
    if (run.get('display_title') != title or run.get('head_sha') != expected_sha or
            run.get('path') != WORKFLOW_PATH or run.get('event') != 'workflow_dispatch' or
            not isinstance(run.get('repository'), dict) or
            run['repository'].get('full_name') != PLATFORM_REPOSITORY):
        raise ValueError('Qualification run trust identity mismatch')
    positive(run.get('id'), 'qualification run ID')
    created = text(run.get('created_at'), r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
                   'qualification creation time')
    created = datetime.fromisoformat(created.replace('Z', '+00:00'))
    if not earliest <= created <= latest:
        raise ValueError('Qualification run creation time is outside the dispatch window')
    if run.get('status') not in ('queued', 'in_progress', 'completed', 'waiting', 'requested', 'pending'):
        raise ValueError('Invalid qualification run status')


def dispatch_and_wait(request, ref, expected_sha, *, api=github_api, request_id=None,
                      monotonic=time.monotonic, sleep=time.sleep,
                      utcnow=lambda: datetime.now(timezone.utc), timeout=TIMEOUT_SECONDS):
    request = validate_request(request)
    validate_trust(ref, expected_sha)
    request_id = text(request_id or secrets.token_hex(16), r'[0-9a-f]{32}', 'request ID')
    if not 0 < timeout <= TIMEOUT_SECONDS:
        raise ValueError('Invalid qualification timeout')
    title = 'Provider qualification ' + request_id
    started = utcnow()
    earliest = started - timedelta(seconds=60)
    latest = started + timedelta(seconds=timeout + 60)
    deadline = monotonic() + timeout

    def call(method, path, payload=None):
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise TimeoutError('Timed out waiting for platform qualification: ' + request_id)
        return api(method, path, payload, timeout=min(30, remaining))

    call('POST', WORKFLOW_API + '/dispatches', {
        'ref': ref,
        'inputs': {'request_id': request_id, 'request': json.dumps(request, separators=(',', ':'))},
    })
    print('Waiting for platform qualification request ' + request_id, flush=True)
    while True:
        matches = []
        page = 1
        while True:
            query = urlencode({'event': 'workflow_dispatch', 'per_page': 100, 'page': page,
                               'created': '>=' + earliest.strftime('%Y-%m-%dT%H:%M:%SZ')})
            result = call('GET', WORKFLOW_API + '/runs?' + query)
            if (not isinstance(result, dict) or type(result.get('total_count')) is not int or
                    not 0 <= result['total_count'] <= 1000 or
                    not isinstance(result.get('workflow_runs'), list)):
                raise ValueError('Invalid or truncated platform workflow run listing')
            runs = result['workflow_runs']
            if any(not isinstance(run, dict) for run in runs):
                raise ValueError('Invalid platform workflow run listing')
            matches.extend(run for run in runs if run.get('display_title') == title)
            if len(matches) > 1:
                raise ValueError('Ambiguous platform qualification request: ' + request_id)
            if page * 100 >= result['total_count']:
                break
            if not runs:
                raise ValueError('Incomplete platform workflow run listing')
            page += 1
        if matches:
            run = matches[0]
            validate_run(run, title, expected_sha, earliest, latest)
            run_id = run['id']
            run = call('GET', f'repos/{PLATFORM_REPOSITORY}/actions/runs/{run_id}')
            validate_run(run, title, expected_sha, earliest, latest)
            if run['id'] != run_id:
                raise ValueError('Qualification run ID mismatch')
            if run['status'] == 'completed':
                if run.get('conclusion') != 'success':
                    raise RuntimeError('Platform qualification did not succeed: ' + str(run.get('conclusion')))
                print(f'Platform qualification succeeded: https://github.com/{PLATFORM_REPOSITORY}/actions/runs/{run_id}')
                return run_id
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise TimeoutError('Timed out waiting for platform qualification: ' + request_id)
        sleep(min(POLL_SECONDS, remaining))


def main():
    try:
        if not os.environ.get('GH_TOKEN'):
            raise ValueError('Missing platform qualification dispatch token')
        dispatch_and_wait(request_from_environment(os.environ),
                          os.environ.get('PLATFORM_QUALIFICATION_REF'),
                          os.environ.get('PLATFORM_QUALIFICATION_SHA'))
    except (ValueError, RuntimeError, TimeoutError) as exc:
        print('Provider qualification failed: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
