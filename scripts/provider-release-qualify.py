#!/usr/bin/env python3
"""C3 independent qualification validator (scripts/provider-release-qualify.py).

Validates a retained Darkbloom provider release bundle against the identity
recorded in `release-payload.json` (or an equivalent `--payload` file), on the
machine that runs it. See docs/specs/0001-contracts.md section C3/C4.

Modes (choose exactly one input):
  --directory D                 D holds release-payload.json,
                                 qualification-request.json and the bundle
                                 (darkbloom-bundle-macos-arm64.tar.gz).
  --bundle PATH --payload FILE  an already-downloaded bundle plus a
                                 release-payload.json-shaped file.
  --url URL --payload FILE      downloads the bundle from URL first.

Checks run once, in the fixed order the contract lists them, and each records
exactly one of passed / failed / not_run plus a short detail. A failed
bundle-digest blocks every later check that depends on the extracted bundle
(binary-digest, metallib-digest, code-directory, codesign, notarization,
team-id, minimum-macos, version, runtime-smoke); lane-host only needs the
host's own macOS version and always runs. Every subprocess call has a
timeout; a timeout or a negative return code (killed by a signal) is
recorded as failed, never passed. KeyboardInterrupt (raised directly, or by
the installed SIGTERM handler) marks whichever check was in flight failed
("interrupted"), marks every later planned check not_run, and still writes
--output before returning exit code 130.
"""
import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 'darkbloom.provider-qualification-result/v1'
TEAM_ID = 'SLDQ2GJ6TL'
CLI_NAME = 'darkbloom'
APP_NAME = 'Darkbloom.app'
BUNDLE_NAME = 'darkbloom-bundle-macos-arm64.tar.gz'

# The 4 markers grep'd by validate-older-macos / validate-macos-27
# (release-swift.yml, "Verify and smoke the exact signed validation
# artifact" / validate-older-macos steps).
REQUIRED_SMOKE_MARKERS = [
    'app-attest-callback-runtime-smoke',
    'gemma-optimizations-runtime-smoke',
    'paged-kernel-runtime-smoke',
    'qwen4-metal-resources-runtime-smoke',
]

IDENTITY_KEYS = [
    'version', 'binary_hash', 'bundle_hash', 'metallib_hash',
    'code_directory_hash', 'source_commit', 'ci_run_id',
]

LIVE_REQUIRED_ENV = [
    'DARKBLOOM_QUALIFY_COORDINATOR', 'DARKBLOOM_QUALIFY_PROVIDER_ID',
    'DARKBLOOM_QUALIFY_API_KEY', 'DARKBLOOM_QUALIFY_MODEL',
]


def _sigterm_to_keyboard_interrupt(signum, frame):
    raise KeyboardInterrupt()


def now_rfc3339():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _version_tuple(value):
    if not value:
        return (0,)
    parts = []
    for chunk in str(value).split('.'):
        digits = ''.join(ch for ch in chunk if ch.isdigit())
        if not digits:
            break
        parts.append(int(digits))
    return tuple(parts) if parts else (0,)


class ToolFailure(Exception):
    """A subprocess timed out or was killed by a signal: always a failed
    check, never a passed one."""


def run_tool(argv, timeout, env=None):
    try:
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise ToolFailure(f'timeout after {timeout}s')


def _checked(proc):
    """Raises ToolFailure for a signal-killed process; returns proc otherwise
    (nonzero non-signal exits are left to the caller to interpret)."""
    if proc.returncode < 0:
        raise ToolFailure(f'killed by signal {-proc.returncode}')
    return proc


# --------------------------------------------------------------------------
# Host inspection
# --------------------------------------------------------------------------

def gather_host():
    host = {}
    proc = _checked(run_tool(['sw_vers', '-productVersion'], timeout=60))
    host['macos'] = proc.stdout.strip() if proc.returncode == 0 else 'unknown'
    for key, argv in (
        ('build', ['sw_vers', '-buildVersion']),
        ('model', ['sysctl', '-n', 'hw.model']),
        ('chip', ['sysctl', '-n', 'machdep.cpu.brand_string']),
    ):
        try:
            proc = _checked(run_tool(argv, timeout=60))
            value = (proc.stdout or '').strip()
            host[key] = value if proc.returncode == 0 and value else 'unknown'
        except Exception:
            host[key] = 'unknown'
    return host


# --------------------------------------------------------------------------
# Input resolution
# --------------------------------------------------------------------------

def load_identity(payload):
    return {k: payload[k] for k in IDENTITY_KEYS}


def resolve_input(args, created_temp_dirs):
    if args.directory:
        d = Path(args.directory)
        payload = json.loads((d / 'release-payload.json').read_text())
        return d / BUNDLE_NAME, load_identity(payload)

    payload = json.loads(Path(args.payload).read_text())
    if args.bundle:
        return Path(args.bundle), load_identity(payload)

    tmp_dir = Path(tempfile.mkdtemp(prefix='darkbloom-qualify-download-'))
    created_temp_dirs.append(tmp_dir)
    dest = tmp_dir / BUNDLE_NAME
    with urllib.request.urlopen(args.url, timeout=120) as resp, open(dest, 'wb') as out:
        shutil.copyfileobj(resp, out)
    return dest, load_identity(payload)


# --------------------------------------------------------------------------
# Safe tar extraction
# --------------------------------------------------------------------------

def _reject_unsafe_member(member):
    name = member.name
    if os.path.isabs(name) or any(part == '..' for part in Path(name).parts):
        raise ValueError(f'unsafe path in bundle archive: {name}')
    if member.issym() or member.islnk():
        target = member.linkname or ''
        if os.path.isabs(target) or any(part == '..' for part in Path(target).parts):
            raise ValueError(f'unsafe link in bundle archive: {name} -> {target}')


def _darwin_setxattr(path, name, value):
    """CPython's os.setxattr is Linux-only (no macOS implementation), so the
    stdlib has no portable call for this. libc's setxattr(2) exists on every
    Darwin, so bind it directly via ctypes rather than shelling out."""
    import ctypes
    import ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
    libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.setxattr.restype = ctypes.c_int
    if libc.setxattr(path.encode('utf-8'), name.encode('utf-8'), value, len(value), 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def _set_xattr(path, name, value):
    if hasattr(os, 'setxattr'):
        os.setxattr(path, name, value)
    elif sys.platform == 'darwin':
        _darwin_setxattr(path, name, value)
    else:
        raise OSError('extended attributes are not supported on this platform')


def _restore_signing_xattrs(dest, members):
    """release-swift.yml extracts the retained bundle with native /usr/bin/tar
    ("Native tar restores the non-Mach-O signing extended attributes"):
    codesign stores the ad-hoc signature of non-Mach-O bundle members (e.g.
    mlx.metallib) in com.apple.cs.* extended attributes, which Python's
    tarfile.extractall never writes back to disk even though it parses them
    into each member's PAX headers (SCHILY.xattr.<name>, surrogateescape-
    decoded). Without this, `codesign --verify --deep --strict` falsely
    reports those members "not signed at all" after a tarfile-based extract."""
    prefix = 'SCHILY.xattr.'
    for member in members:
        headers = getattr(member, 'pax_headers', None) or {}
        xattrs = {k[len(prefix):]: v for k, v in headers.items() if k.startswith(prefix)}
        if not xattrs:
            continue
        target = dest / member.name
        if not target.is_file():
            continue
        for name, value in xattrs.items():
            try:
                _set_xattr(str(target), name, value.encode('utf-8', 'surrogateescape'))
            except OSError:
                pass


def _normalize_member_name(name):
    return name[2:] if name.startswith('./') else name


def _drop_apple_double_sidecars(members):
    """The release build's archive carries some non-Mach-O signatures twice:
    once as PAX SCHILY.xattr.* headers on the real entry (restored above),
    and once more as a legacy AppleDouble sidecar entry (`._name`, empty PAX
    headers) next to it, for tools that don't understand PAX xattrs. Native
    tar consumes/discards that sidecar on extraction rather than writing it
    out as a visible file; tarfile.extractall does not, and the stray file
    then makes the app bundle's sealed-resource manifest (_CodeSignature/
    CodeResources) invalid. Drop only sidecars that have a real counterpart
    entry, exactly matching what native tar leaves on disk."""
    names = {_normalize_member_name(m.name) for m in members}
    kept = []
    for member in members:
        norm = _normalize_member_name(member.name)
        dirpart, base = posixpath.split(norm)
        if base.startswith('._') and len(base) > 2:
            real = posixpath.join(dirpart, base[2:]) if dirpart else base[2:]
            if real in names:
                continue
        kept.append(member)
    return kept


def safe_extract(bundle_path, dest):
    with tarfile.open(bundle_path, 'r:gz') as tar:
        all_members = tar.getmembers()
        for member in all_members:
            _reject_unsafe_member(member)
        members = _drop_apple_double_sidecars(all_members)
        try:
            tar.extractall(dest, members=members, filter='data')
        except TypeError:
            # Python < 3.12 without PEP 706 filter support: members were
            # already vetted above.
            tar.extractall(dest, members=members)
        _restore_signing_xattrs(dest, members)


def prepare_bundle(bundle_path, identity):
    raw_hash = sha256_file(bundle_path)
    bundle_ok = raw_hash == identity['bundle_hash']
    bundle_detail = raw_hash if bundle_ok else (
        f'bundle sha256 {raw_hash} != recorded bundle_hash {identity["bundle_hash"]}')

    extract_root = app_root = app_binary = bin_binary = app_metallib = None
    if bundle_ok:
        try:
            extract_root = Path(tempfile.mkdtemp(prefix='darkbloom-qualify-extract-'))
            safe_extract(bundle_path, extract_root)
            app_root = extract_root / APP_NAME
            app_binary = app_root / 'Contents' / 'MacOS' / CLI_NAME
            app_metallib = app_root / 'Contents' / 'MacOS' / 'mlx.metallib'
            bin_binary = extract_root / 'bin' / CLI_NAME
        except Exception as exc:
            bundle_ok = False
            bundle_detail = f'bundle sha256 matched but extraction failed: {exc}'

    return {
        'bundle_ok': bundle_ok, 'bundle_detail': bundle_detail,
        'extract_root': extract_root, 'app_root': app_root,
        'app_binary': app_binary, 'bin_binary': bin_binary, 'app_metallib': app_metallib,
        'codesign_d': None, 'minos': None,
    }


# --------------------------------------------------------------------------
# static + smoke checks
# --------------------------------------------------------------------------

def check_bundle_digest(ctx):
    return ('passed' if ctx['bundle_ok'] else 'failed'), ctx['bundle_detail']


def check_binary_digest(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    app_binary, bin_binary = ctx['app_binary'], ctx['bin_binary']
    if not app_binary.exists():
        return 'failed', f'Darkbloom.app/Contents/MacOS/{CLI_NAME} missing from extracted bundle'
    if not bin_binary.exists():
        return 'failed', f'bin/{CLI_NAME} missing from extracted bundle'
    app_bytes = app_binary.read_bytes()
    computed = hashlib.sha256(app_bytes).hexdigest()
    if computed != ctx['identity']['binary_hash']:
        return 'failed', (f'Darkbloom.app/Contents/MacOS/{CLI_NAME} sha256 {computed} != '
                           f'recorded binary_hash {ctx["identity"]["binary_hash"]}')
    if app_bytes != bin_binary.read_bytes():
        return 'failed', (f'Darkbloom.app/Contents/MacOS/{CLI_NAME} is not byte-identical '
                           f'to bin/{CLI_NAME}')
    return 'passed', computed


def check_metallib_digest(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    app_metallib = ctx['app_metallib']
    if not app_metallib.exists():
        return 'failed', 'Darkbloom.app/Contents/MacOS/mlx.metallib missing from extracted bundle'
    computed = sha256_file(app_metallib)
    if computed != ctx['identity']['metallib_hash']:
        return 'failed', (f'mlx.metallib sha256 {computed} != '
                           f'recorded metallib_hash {ctx["identity"]["metallib_hash"]}')
    return 'passed', computed


def get_codesign_d(ctx):
    if ctx.get('codesign_d') is not None:
        return ctx['codesign_d']
    proc = _checked(run_tool(['codesign', '-d', '--verbose=4', str(ctx['app_binary'])], timeout=60))
    if proc.returncode != 0:
        result = {'error': f'codesign -d exited {proc.returncode}: {(proc.stderr or "").strip()}'}
    else:
        text = (proc.stdout or '') + (proc.stderr or '')
        cd_match = re.search(r'CandidateCDHashFull sha256=([0-9a-fA-F]+)', text)
        team_match = re.search(r'TeamIdentifier=(\S+)', text)
        result = {'cdhash': cd_match.group(1) if cd_match else None,
                  'team_id': team_match.group(1) if team_match else None}
    ctx['codesign_d'] = result
    return result


def check_code_directory(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    info = get_codesign_d(ctx)
    if info.get('error'):
        return 'failed', info['error']
    cdhash = info.get('cdhash')
    if not cdhash:
        return 'failed', 'CandidateCDHashFull sha256=... not found in codesign -d output'
    if cdhash.lower() != ctx['identity']['code_directory_hash'].lower():
        return 'failed', (f'CandidateCDHashFull sha256={cdhash} != recorded '
                           f'code_directory_hash {ctx["identity"]["code_directory_hash"]}')
    return 'passed', f'CandidateCDHashFull sha256={cdhash}'


def check_team_id(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    info = get_codesign_d(ctx)
    if info.get('error'):
        return 'failed', info['error']
    team_id = info.get('team_id')
    if team_id != TEAM_ID:
        return 'failed', f'TeamIdentifier={team_id} != expected {TEAM_ID}'
    return 'passed', f'TeamIdentifier={team_id}'


def check_codesign_verify(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    proc = _checked(run_tool(['codesign', '--verify', '--deep', '--strict', str(ctx['app_root'])],
                              timeout=60))
    if proc.returncode != 0:
        return 'failed', f'codesign --verify --deep --strict exited {proc.returncode}: {(proc.stderr or "").strip()}'
    return 'passed', 'codesign --verify --deep --strict ok'


def check_notarization(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    proc = _checked(run_tool(['xcrun', 'stapler', 'validate', str(ctx['app_root'])], timeout=60))
    if proc.returncode != 0:
        return 'failed', (f'xcrun stapler validate exited {proc.returncode}: '
                           f'{((proc.stderr or "").strip() or (proc.stdout or "").strip())}')
    return 'passed', (proc.stdout or '').strip() or 'xcrun stapler validate ok'


def get_minos(ctx):
    if ctx.get('minos') is not None:
        return ctx['minos']
    try:
        proc = _checked(run_tool(['vtool', '-show-build', str(ctx['app_binary'])], timeout=60))
    except FileNotFoundError:
        proc = _checked(run_tool(['otool', '-l', str(ctx['app_binary'])], timeout=60))
    text = (proc.stdout or '') + (proc.stderr or '')
    m = re.search(r'minos\s+(\d+(?:\.\d+)*)', text)
    ctx['minos'] = m.group(1) if m else None
    return ctx['minos']


def check_minimum_macos(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    minos = get_minos(ctx)
    if not minos:
        return 'failed', 'could not determine the binary minimum macOS (minos) via vtool/otool'
    host_macos = ctx['host']['macos']
    if _version_tuple(minos) <= _version_tuple(host_macos):
        return 'passed', f'binary minos {minos} <= host macOS {host_macos}'
    return 'failed', f'binary minos {minos} > host macOS {host_macos}'


def check_lane_host(ctx, lane):
    host_macos = ctx['host']['macos']
    major = _version_tuple(host_macos)[0]
    if lane == 'macos-27':
        if major >= 27:
            return 'passed', f'host macOS {host_macos} satisfies macos-27 lane (major >= 27)'
        return 'failed', f'host macOS {host_macos} does not satisfy macos-27 lane (major >= 27 required)'
    if 14 <= major < 27:
        return 'passed', f'host macOS {host_macos} satisfies older-macos lane (14 <= major < 27)'
    return 'failed', f'host macOS {host_macos} does not satisfy older-macos lane (14 <= major < 27 required)'


def check_version(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    proc = _checked(run_tool([str(ctx['app_binary']), '--version'], timeout=60))
    if proc.returncode != 0:
        return 'failed', f'{CLI_NAME} --version exited {proc.returncode}: {(proc.stderr or "").strip()}'
    lines = [line for line in (proc.stdout or '').splitlines() if line.strip()]
    last = lines[-1].strip() if lines else ''
    expected = ctx['identity']['version']
    if last != expected:
        return 'failed', f'--version reported {last!r}, expected {expected!r}'
    return 'passed', last


def check_runtime_smoke(ctx):
    if not ctx['bundle_ok']:
        return 'not_run', 'blocked by bundle-digest'
    # Mirrors validate-older-macos's "Verify and smoke the exact signed
    # validation artifact" step (release-swift.yml): the retained, already
    # signed/notarized bundle only needs DARKBLOOM_NO_UPDATE_CHECK=1, and
    # checks all 4 markers (the pre-sign smoke, by contrast, checks only 3).
    env = dict(os.environ)
    env['DARKBLOOM_NO_UPDATE_CHECK'] = '1'
    proc = _checked(run_tool([str(ctx['app_binary']), 'runtime-smoke'], timeout=600, env=env))
    if proc.returncode != 0:
        return 'failed', f'runtime-smoke exited {proc.returncode}: {(proc.stderr or "").strip()}'
    lines = {line.strip() for line in (proc.stdout or '').splitlines()}
    missing = [m for m in REQUIRED_SMOKE_MARKERS if f'{m}: ok' not in lines]  # same test as release-swift.yml
    if missing:
        return 'failed', f'missing runtime-smoke markers: {", ".join(missing)}'
    return 'passed', f'observed all {len(REQUIRED_SMOKE_MARKERS)} runtime-smoke markers'


# --------------------------------------------------------------------------
# live checks (DARKBLOOM_QUALIFY_LIVE=1 only; not exercised by the required
# test suite, kept intentionally small)
# --------------------------------------------------------------------------

def _missing_live_env():
    for name in LIVE_REQUIRED_ENV:
        if not os.environ.get(name):
            return name
    return None


def _coord_url():
    return os.environ['DARKBLOOM_QUALIFY_COORDINATOR'].rstrip('/')


def _http_json(method, url, headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req_headers = dict(headers or {})
    if data is not None:
        req_headers.setdefault('Content-Type', 'application/json')
    req = urllib.request.Request(url, data=data, method=method, headers=req_headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode() or '{}'
        return resp.status, json.loads(raw)


def _fetch_requests_served(ctx):
    _, data = _http_json('GET', f'{_coord_url()}/v1/stats', timeout=60)
    provider_id = os.environ['DARKBLOOM_QUALIFY_PROVIDER_ID']
    for p in data.get('providers', []):
        if p.get('id') == provider_id:
            return p.get('requests_served', 0)
    return None


def live_app_attest(ctx):
    try:
        _, data = _http_json('GET', f'{_coord_url()}/v1/providers/attestation', timeout=60)
    except Exception as exc:
        return 'failed', f'GET /v1/providers/attestation error: {exc}'
    provider_id = os.environ['DARKBLOOM_QUALIFY_PROVIDER_ID']
    entry = next((p for p in data.get('providers', []) if p.get('provider_id') == provider_id), None)
    if entry is None:
        return 'failed', f'provider_id {provider_id} not present in GET /v1/providers/attestation'
    state = ((entry.get('verification') or {}).get('app_attest') or {}).get('state')
    authorized = entry.get('app_attest_authorized') is True
    if authorized and state == 'verified':
        return 'passed', 'app_attest_authorized=true, verification.app_attest.state=verified'
    return 'failed', f'app_attest_authorized={entry.get("app_attest_authorized")} verification.app_attest.state={state!r}'


def live_inference(ctx):
    provider_id = os.environ['DARKBLOOM_QUALIFY_PROVIDER_ID']
    api_key = os.environ['DARKBLOOM_QUALIFY_API_KEY']
    model = os.environ['DARKBLOOM_QUALIFY_MODEL']
    body = {'model': model, 'stream': False, 'max_tokens': 8,
            'messages': [{'role': 'user', 'content': 'ok'}]}
    # coordinator/api/self_route.go: X-Darkbloom-Route: self forces EXCLUSIVE
    # self-route to a provider owned by this key's account, with no paid
    # fallback -- the only forgery-proof way to pin this request to `id`.
    try:
        status, data = _http_json('POST', f'{_coord_url()}/v1/chat/completions', body=body,
                                   headers={'Authorization': f'Bearer {api_key}',
                                            'X-Darkbloom-Route': 'self'}, timeout=60)
    except Exception as exc:
        return 'failed', f'POST /v1/chat/completions error: {exc}'
    if status != 200:
        return 'failed', f'POST /v1/chat/completions returned {status}'
    choices = data.get('choices') or [{}]
    content = (choices[0].get('message') or {}).get('content')
    if not content:
        return 'failed', 'response had no choices[0].message.content'
    return 'passed', f'self-routed inference on provider {provider_id} returned {len(content)} chars'


def live_graceful_drain(ctx):
    if not ctx.get('bundle_ok'):
        return 'not_run', 'blocked by bundle-digest'
    api_key = os.environ['DARKBLOOM_QUALIFY_API_KEY']
    model = os.environ['DARKBLOOM_QUALIFY_MODEL']
    body = {'model': model, 'stream': True, 'max_tokens': 512,
            'messages': [{'role': 'user', 'content': 'Count from 1 to 100, one number per line.'}]}
    result = {}

    def stream_worker():
        try:
            req = urllib.request.Request(
                f'{_coord_url()}/v1/chat/completions', data=json.dumps(body).encode(), method='POST',
                headers={'Authorization': f'Bearer {api_key}', 'X-Darkbloom-Route': 'self',
                         'Content-Type': 'application/json', 'Accept': 'text/event-stream'})
            with urllib.request.urlopen(req, timeout=180) as resp:
                for raw_line in resp:
                    line = raw_line.decode(errors='replace').strip()
                    if not line.startswith('data:'):
                        continue
                    payload = line[len('data:'):].strip()
                    if payload == '[DONE]':
                        result['done_seen'] = True
                        break
                    try:
                        chunk = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    choice = (chunk.get('choices') or [{}])[0]
                    if (choice.get('delta') or {}).get('content') and 'first_content_at' not in result:
                        result['first_content_at'] = time.monotonic()
                    if choice.get('finish_reason'):
                        result['finish_reason_seen'] = True
        except Exception as exc:
            result['error'] = str(exc)

    thread = threading.Thread(target=stream_worker, daemon=True)
    thread.start()
    deadline = time.monotonic() + 30
    while 'first_content_at' not in result and time.monotonic() < deadline and thread.is_alive():
        time.sleep(0.2)
    if 'first_content_at' not in result:
        thread.join(timeout=5)
        return 'failed', f'no content chunk observed before stop: {result.get("error", "timed out")}'

    # provider-swift/Sources/darkbloom/ServiceDrain.swift DrainOptions.timeout.
    try:
        stop_proc = _checked(run_tool([str(ctx['app_binary']), 'stop', '--timeout', '60'], timeout=90))
        stop_ok, stop_detail = stop_proc.returncode == 0, f'stop exit {stop_proc.returncode}'
    except ToolFailure as exc:
        stop_ok, stop_detail = False, f'stop failed: {exc}'

    thread.join(timeout=180)
    stream_ok = bool(result.get('finish_reason_seen')) and bool(result.get('done_seen')) and not result.get('error')

    try:
        start_proc = _checked(run_tool([str(ctx['app_binary']), 'start'], timeout=60))
        start_ok, start_detail = start_proc.returncode == 0, f'start exit {start_proc.returncode}'
    except ToolFailure as exc:
        start_ok, start_detail = False, f'start failed: {exc}'

    status = 'passed' if (stop_ok and stream_ok and start_ok) else 'failed'
    detail = (f'stream(finish_reason={bool(result.get("finish_reason_seen"))}, '
              f'done={bool(result.get("done_seen"))}); {stop_detail}; restart: {start_detail}')
    if not start_ok:
        detail += ' (failure to restart = failed)'
    return status, detail


def live_accounting(ctx):
    baseline = ctx.get('accounting_baseline')
    if baseline is None:
        return 'failed', f'could not establish accounting baseline for provider {os.environ["DARKBLOOM_QUALIFY_PROVIDER_ID"]}'
    deadline = time.monotonic() + 120
    last = baseline
    while time.monotonic() < deadline:
        try:
            current = _fetch_requests_served(ctx)
        except Exception:
            current = None
        if current is not None:
            last = current
            if current >= baseline + 2:
                return 'passed', f'requests_served {current} >= baseline {baseline} + 2'
        time.sleep(3)
    return 'failed', f'requests_served stayed at {last} (baseline {baseline}), never reached {baseline + 2} within 120s'


def check_live(ctx, name):
    if not ctx.get('live_active'):
        return 'not_run', 'live lane not requested'
    missing = _missing_live_env()
    if missing:
        return 'failed', f'missing env {missing}'
    if 'accounting_baseline' not in ctx:
        try:
            ctx['accounting_baseline'] = _fetch_requests_served(ctx)
        except Exception:
            ctx['accounting_baseline'] = None
    if name == 'app-attest':
        return live_app_attest(ctx)
    if name == 'inference':
        return live_inference(ctx)
    if name == 'graceful-drain':
        return live_graceful_drain(ctx)
    if name == 'accounting':
        return live_accounting(ctx)
    return 'not_run', f'unrecognised live check {name}'


# --------------------------------------------------------------------------
# Plan + execution
# --------------------------------------------------------------------------

class _CheckPlan:
    __slots__ = ('name', 'level', 'fn')

    def __init__(self, name, level, fn):
        self.name, self.level, self.fn = name, level, fn


def build_plan(levels, lane, ctx):
    plan = []
    if 'static' in levels:
        plan += [
            _CheckPlan('bundle-digest', 'static', lambda: check_bundle_digest(ctx)),
            _CheckPlan('binary-digest', 'static', lambda: check_binary_digest(ctx)),
            _CheckPlan('metallib-digest', 'static', lambda: check_metallib_digest(ctx)),
            _CheckPlan('code-directory', 'static', lambda: check_code_directory(ctx)),
            _CheckPlan('codesign', 'static', lambda: check_codesign_verify(ctx)),
            _CheckPlan('notarization', 'static', lambda: check_notarization(ctx)),
            _CheckPlan('team-id', 'static', lambda: check_team_id(ctx)),
            _CheckPlan('minimum-macos', 'static', lambda: check_minimum_macos(ctx)),
            _CheckPlan('lane-host', 'static', lambda: check_lane_host(ctx, lane)),
        ]
    if 'smoke' in levels:
        plan += [
            _CheckPlan('version', 'smoke', lambda: check_version(ctx)),
            _CheckPlan('runtime-smoke', 'smoke', lambda: check_runtime_smoke(ctx)),
        ]
    if 'live' in levels:
        names = ['app-attest', 'inference', 'graceful-drain', 'accounting'] if lane == 'macos-27' \
            else ['inference', 'graceful-drain', 'accounting']
        for name in names:
            plan.append(_CheckPlan(name, 'live', lambda name=name: check_live(ctx, name)))
    return plan


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog='provider-release-qualify.py',
        description='Independently qualify a retained Darkbloom provider release bundle (C3).')
    parser.add_argument('--directory', help='retained publication directory')
    parser.add_argument('--bundle', help='path to an already-downloaded bundle tar.gz')
    parser.add_argument('--url', help='URL to download the bundle tar.gz from')
    parser.add_argument('--payload', help='release-payload.json-shaped file (with --bundle/--url)')
    parser.add_argument('--lane', required=True, choices=['macos-27', 'older-macos'])
    parser.add_argument('--level', required=True, help='comma-separated: static,smoke[,live]')
    parser.add_argument('--output', required=True)
    args = parser.parse_args(argv)
    if not args.directory and not args.bundle and not args.url:
        parser.error('one of --directory, --bundle or --url is required')
    if (args.bundle or args.url) and not args.payload:
        parser.error('--payload is required with --bundle or --url')
    return args


def write_output(path, result):
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + '\n')


def main():
    args = parse_args(sys.argv[1:])
    signal.signal(signal.SIGTERM, _sigterm_to_keyboard_interrupt)

    levels = [level.strip() for level in args.level.split(',') if level.strip()]
    started_at = now_rfc3339()
    created_temp_dirs = []
    extract_root = None
    identity = {}
    host = {'macos': 'unknown', 'build': 'unknown', 'model': 'unknown', 'chip': 'unknown'}
    checks_result = []
    interrupted = False
    plan = None
    idx = None

    try:
        bundle_path, identity = resolve_input(args, created_temp_dirs)
        host = gather_host()
        prepared = prepare_bundle(bundle_path, identity)
        extract_root = prepared.get('extract_root')
        ctx = dict(prepared)
        ctx['identity'] = identity
        ctx['host'] = host
        ctx['live_active'] = ('live' in levels) and os.environ.get('DARKBLOOM_QUALIFY_LIVE') == '1'

        plan = build_plan(levels, args.lane, ctx)
        for idx, item in enumerate(plan):
            try:
                status, detail = item.fn()
            except Exception as exc:  # ToolFailure, or any unexpected tool/parse error
                status, detail = 'failed', str(exc)
            checks_result.append({'name': item.name, 'level': item.level,
                                   'status': status, 'detail': detail})
    except KeyboardInterrupt:
        interrupted = True
        if plan is not None and idx is not None and len(checks_result) <= idx:
            checks_result.append({'name': plan[idx].name, 'level': plan[idx].level,
                                   'status': 'failed', 'detail': 'interrupted'})
            for item in plan[idx + 1:]:
                checks_result.append({'name': item.name, 'level': item.level,
                                       'status': 'not_run', 'detail': 'not run: interrupted'})
    finally:
        for d in created_temp_dirs:
            shutil.rmtree(d, ignore_errors=True)
        if extract_root is not None:
            shutil.rmtree(extract_root, ignore_errors=True)

    finished_at = now_rfc3339()
    result = {
        'schema': SCHEMA, 'lane': args.lane, 'identity': identity, 'host': host,
        'levels': levels, 'started_at': started_at, 'finished_at': finished_at,
        'checks': checks_result,
    }
    write_output(args.output, result)

    if interrupted:
        return 130
    ok = bool(checks_result) and all(c['status'] == 'passed' for c in checks_result)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
