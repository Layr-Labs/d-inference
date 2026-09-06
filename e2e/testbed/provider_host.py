"""Owned testbed host helper. One JSON control pipe; no production connection."""
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time

MAX_CONTROL = 1 << 20
MAX_STATE = 1 << 20


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            value.update(chunk)
    return value.hexdigest()


def check_file(path, expected):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise ValueError('manifest file must be regular: ' + str(path))
    if (info.st_size != expected['bytes'] or stat.S_IMODE(info.st_mode) != expected['mode']
            or digest(path) != expected['sha256']):
        raise ValueError('manifest identity differs: ' + str(path))


def safe_file(root, relative):
    path = Path(relative)
    if path.is_absolute() or not path.parts or '..' in path.parts or str(path) != relative:
        raise ValueError('invalid manifest relative path')
    result = root/path
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError('manifest escapes declared root')
    return result


def canonical_owned_root(path, home):
    root = Path(path)
    if not root.is_absolute() or '..' in root.parts or root.name in ('', '.', '..'):
        raise ValueError('invalid owned root')
    if root.exists() or root.is_symlink():
        raise ValueError('owned root already exists')
    # Resolve an existing parent before appending the absent leaf. Do not create
    # directories while deciding whether a requested root aliases protected data.
    parent = root.parent.resolve(strict=True)
    if not parent.is_dir():
        raise ValueError('owned parent is not a directory')
    resolved = parent/root.name
    for protected in (home, home/'.darkbloom', home/'.config/darkbloom', home/'.cache/huggingface'):
        target = protected.resolve()
        if resolved == target or (protected != home and target in resolved.parents) or resolved in target.parents:
            raise ValueError('owned root aliases protected host data')
    return resolved


def observe(target, owned=()):
    rows = []
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=10)
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) < 2:
            continue
        pid = int(fields[0])
        if pid in owned or pid == os.getpid():
            continue
        name = Path(fields[1]).name
        if name in ('darkbloom', 'radix-engine', 'attention-replay', 'Runner.Worker', 'benchctl', 'measure-job.sh'):
            rows.append(pid)
    check_file(Path(target['macmon_path']), target['macmon'])
    raw = subprocess.check_output([target['macmon_path'], 'pipe', '-s', '1', '-i', '200'], text=True, timeout=10)
    temperature = json.loads(raw.splitlines()[0])['temp']['gpu_temp_avg']
    return {'hardware_model': subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip(),
            'memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
            'gpu_temperature_c': temperature, 'load1': os.getloadavg()[0],
            'free_bytes': shutil.disk_usage(str(Path.home())).free,
            'unexpected_processes': rows, 'owned_processes': list(owned)}


def require_entry(value):
    if (value['unexpected_processes'] or value['owned_processes']
            or not math.isfinite(value['gpu_temperature_c']) or not 0 <= value['gpu_temperature_c'] <= 42
            or not math.isfinite(value['load1']) or not 0 <= value['load1'] <= 4
            or value['free_bytes'] <= 100*(1 << 30)):
        raise ValueError('host not ready for measured entry')


def model_file(snapshot, relative):
    path = Path(relative)
    if path.is_absolute() or not path.parts or '..' in path.parts or str(path) != relative:
        raise ValueError('invalid model relative path')
    resolved = (snapshot/path).resolve(strict=True)
    allowed = [snapshot]
    # Standard HF snapshots link immutable files into their own model's blobs.
    # Permit those bounded resolved files, never another model/default directory.
    if snapshot.parent.name == 'snapshots':
        blobs = snapshot.parent.parent/'blobs'
        if blobs.exists():
            allowed.append(blobs.resolve(strict=True))
    if not any(resolved.is_relative_to(root) for root in allowed):
        raise ValueError('model symlink escapes selected snapshot/blob store')
    return resolved


def verify_models(target, home):
    for model in target['models']:
        snapshot = Path(model['snapshot']).resolve(strict=True)
        for name, row in model['files'].items():
            check_file(model_file(snapshot, name), row)
        if target.get('assistant_path') and snapshot == Path(target['assistant_path']).resolve(strict=True):
            continue  # The assistant uses this explicit verified path, not HF discovery.
        # Match the provider's current exact-ID, latest-directory resolver. This
        # never creates a model alias or downloads/substitutes another artifact.
        hub = home/'.cache/huggingface/hub'
        selected = None
        for folder in ('models--'+model['id'].replace('/', '--'), 'models--'+model['id']):
            parent = hub/folder
            if parent.exists():
                candidates = [p for p in (parent/'snapshots').iterdir() if not p.name.startswith('.') and p.is_dir()]
                if candidates:
                    selected = max(candidates, key=lambda p: p.stat().st_mtime).resolve()
                    break
        if selected != snapshot:
            raise ValueError('provider model resolution differs from selected snapshot')


def prepare(request):
    target, spec = request['target'], request['spec']
    home = Path.home()
    root = canonical_owned_root(target['root'], home)
    if spec['root'] != target['root']:
        raise ValueError('launch root differs from target')
    canonical = home/'.config/darkbloom/provider.toml'
    if digest(canonical) != target['canonical_config_sha256']:
        raise ValueError('canonical config differs; no repair performed')
    for relative in ('.darkbloom/telemetry-queue.jsonl', '.darkbloom/telemetry-queue.jsonl.tmp'):
        path = home/relative
        if path.exists() or path.is_symlink():
            raise ValueError('retired startup artifact exists; no deletion performed')
    runtime = Path(target['runtime_directory']).resolve(strict=True)
    if root == runtime or root in runtime.parents or runtime in root.parents:
        raise ValueError('owned root overlaps source runtime')
    for name, row in target['runtime_files'].items():
        check_file(safe_file(runtime, name), row)
    entitlement = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(runtime/'darkbloom')],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    if entitlement.returncode != 0 or b'keychain-access-groups' in entitlement.stdout:
        raise ValueError('verifiably unentitled fixture runtime required')
    for model in target['models']:
        snapshot = Path(model['snapshot']).resolve(strict=True)
        if root == snapshot or root in snapshot.parents or snapshot in root.parents:
            raise ValueError('owned root overlaps selected model input')
    verify_models(target, home)
    observation = observe(target)
    require_entry(observation)
    if (observation['hardware_model'] != target['hardware_model']
            or observation['memory_bytes'] != target['memory_bytes']):
        raise ValueError('host hardware identity differs')
    # Hash a hardware identifier with a suite-scoped nonce; never export a raw
    # serial/UUID. Two aliases of one machine cannot claim independent hosts.
    hardware = subprocess.check_output(['ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'], text=True, timeout=10)
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', hardware)
    if not match:
        raise ValueError('host identity unavailable')
    host_id = hashlib.sha256((request['suite_nonce']+match.group(1)).encode()).hexdigest()
    token = base64.b64decode(request['auth_token'], validate=True)
    if not token or len(token) > 4096 or b'\0' in token:
        raise ValueError('invalid private provider token')
    root.mkdir(mode=0o700)
    (root/'runtime').mkdir(mode=0o700)
    for name, row in target['runtime_files'].items():
        destination = root/'runtime'/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(runtime/name, destination)
        check_file(destination, row)
    (root/'tmp').mkdir(mode=0o700)
    for name, raw in (('provider.toml', spec['config'].encode()), ('auth_token', token)):
        descriptor = os.open(root/name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(raw)
    return root, canonical, host_id, observation


def send(value):
    sys.stdout.write(json.dumps(value, allow_nan=False)+'\n')
    sys.stdout.flush()


def retire_group(process, record):
    # Descendants retain the owned process group even if its original leader
    # has exited. Retire that group before considering the host clean.
    group = process.pid
    record['pgid'] = group
    record['signals_sent'] = []
    record['signal_errors'] = []
    def present():
        process.poll()  # Darwin can return EPERM for an unreaped zombie group.
        try:
            os.killpg(group, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True  # Never interpret an inaccessible group as absent.
    def terminate(sig):
        try:
            os.killpg(group, sig)
            record['signals_sent'].append(int(sig))
        except ProcessLookupError:
            pass
        except PermissionError as error:
            record['signal_errors'].append(str(error))
    terminate(signal.SIGTERM)
    deadline = time.monotonic()+10
    while present() and time.monotonic() < deadline:
        process.poll()  # Reap the direct child; descendants remain in the group.
        time.sleep(0.02)
    if present():
        terminate(signal.SIGKILL)
    record['exit_code'] = process.wait(timeout=10)
    deadline = time.monotonic()+2
    while present() and time.monotonic() < deadline:
        time.sleep(0.02)
    record['group_cleanup_complete'] = not present()
    if not record['group_cleanup_complete']:
        record['failure'] = (record['failure'] or '')+' owned process group still present'


def run_owner(command, environment, root, control, emit, lease_seconds=30, deadline_seconds=1800, observation=None):
    """Own one child group until explicit stop, pipe EOF, lease or deadline."""
    selector = selectors.DefaultSelector()
    selector.register(control, selectors.EVENT_READ)
    process = None
    record = {'event': 'terminal', 'pid': None, 'exit_code': None, 'failure': None, 'stop_requested': False}
    signals = (signal.SIGHUP, signal.SIGTERM, signal.SIGINT)
    old_handlers = {sig: signal.getsignal(sig) for sig in signals}
    class OwnerInterrupted(Exception):
        pass
    def interrupted(signum, _frame):
        for sig in signals:
            signal.signal(sig, signal.SIG_IGN)
        raise OwnerInterrupted('owner signal '+str(signum))
    for sig in signals:
        signal.signal(sig, interrupted)
    start = last_control = time.monotonic()
    pending = b''
    try:
        with (root/'provider.log').open('xb') as log:
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
            try:
                process = subprocess.Popen(command, env=environment, stdout=log, stderr=log, start_new_session=True,
                                           preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask))
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            record['pid'] = process.pid
            emit({'event': 'started', 'pid': process.pid, 'pgid': process.pid})
            while process.poll() is None:
                now = time.monotonic()
                if now-start >= deadline_seconds:
                    raise TimeoutError('owned process deadline expired')
                if now-last_control >= lease_seconds:
                    raise TimeoutError('controller lease expired')
                if not selector.select(min(0.25, lease_seconds)):
                    continue
                chunk = os.read(control.fileno(), 4096)
                if not chunk:
                    raise OwnerInterrupted('controller pipe EOF')
                pending += chunk
                if len(pending) > MAX_CONTROL:
                    raise ValueError('control frame exceeds limit')
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    message = json.loads(line)
                    last_control = time.monotonic()
                    kind = message.get('command')
                    if kind == 'stop':
                        record['stop_requested'] = True
                        return record
                    if kind == 'ping':
                        continue
                    request_id = message.get('id')
                    if not isinstance(request_id, int) or isinstance(request_id, bool) or request_id <= 0:
                        raise ValueError('positive control request identity required')
                    if kind == 'observe' and observation is not None:
                        emit({'event': 'observation', 'id': request_id, 'observation': observation(process.pid)})
                        continue
                    if kind != 'state':
                        raise ValueError('unknown controller operation')
                    path = root/'daemon-state.json'
                    try:
                        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                    except FileNotFoundError:
                        emit({'event': 'state', 'id': request_id, 'error': 'not_ready', 'retryable': True})
                        continue
                    with os.fdopen(descriptor, 'rb') as stream:
                        info = os.fstat(stream.fileno())
                        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_STATE:
                            raise ValueError('invalid bounded state file')
                        raw = stream.read(MAX_STATE+1)
                    if len(raw) > MAX_STATE:
                        raise ValueError('state exceeds limit')
                    emit({'event': 'state', 'id': request_id, 'body': base64.b64encode(raw).decode()})
    except Exception as error:
        record['failure'] = type(error).__name__+': '+str(error)
    finally:
        for sig in signals:
            signal.signal(sig, signal.SIG_IGN)
        try:
            if process is not None:
                record['pid'] = process.pid
                try:
                    retire_group(process, record)
                except Exception as error:
                    record['group_cleanup_complete'] = False
                    record['failure'] = (record['failure'] or '')+' cleanup '+type(error).__name__+': '+str(error)
            record['seconds'] = time.monotonic()-start
            (root/'terminal.json').write_text(json.dumps(record, indent=2)+'\n')
            try:
                emit(record)
            except (BrokenPipeError, OSError):
                pass
        finally:
            selector.close()
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
    return record


def main():
    first = sys.stdin.buffer.readline(MAX_CONTROL+1)
    if len(first) > MAX_CONTROL or not first.endswith(b'\n'):
        raise ValueError('bounded initial control frame required')
    request = json.loads(first)
    root, canonical, host_id, observation = prepare(request)
    send({'event': 'prepared', 'host_id': host_id, 'observation': observation, 'root': str(root)})
    spec = request['spec']
    environment = {'HOME': str(Path.home()), 'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'}
    environment.update(spec['environment'])
    environment['DARKBLOOM_AUTH_TOKEN_PATH'] = str(root/'auth_token')
    record = run_owner([str(root/'runtime/darkbloom')]+spec['arguments'], environment, root, sys.stdin.buffer, send, observation=lambda pid: observe(request['target'], (pid,)))
    if digest(canonical) != request['target']['canonical_config_sha256']:
        raise ValueError('canonical config changed; no repair performed')
    cleanup = observe(request['target'])
    send({'event': 'cleanup', 'observation': cleanup})
    if cleanup['unexpected_processes'] or cleanup['owned_processes']:
        raise ValueError('process leftovers after owned shutdown')
    # The model/runtime/cache evidence remains owned and intact. Only the
    # private fixture auth token is removed after its process has been reaped.
    (root/'auth_token').unlink()
    if record['failure'] is not None or (record['exit_code'] != 0 and not record['stop_requested']):
        raise RuntimeError(record['failure'] or 'provider exited without requested shutdown')


if __name__ == '__main__':
    main()
