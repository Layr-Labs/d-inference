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


def digest(path, checkpoint=None):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            if checkpoint is not None:
                checkpoint()
            value.update(chunk)
    return value.hexdigest()


def check_file(path, expected, checkpoint=None):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise ValueError('manifest file must be regular: ' + str(path))
    if (info.st_size != expected['bytes'] or stat.S_IMODE(info.st_mode) != expected['mode']
            or digest(path, checkpoint) != expected['sha256']):
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
    return {'hardware_model': subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True, timeout=10).strip(),
            'memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True, timeout=10)),
            'gpu_temperature_c': temperature, 'load1': os.getloadavg()[0],
            'free_bytes': shutil.disk_usage(str(Path.home())).free,
            'unexpected_processes': rows, 'owned_processes': list(owned)}


def entry_refusal(value):
    if value['unexpected_processes'] or value['owned_processes']:
        return 'foreign or already-owned processes present', False
    temperature, load = value['gpu_temperature_c'], value['load1']
    if not math.isfinite(temperature) or temperature < 0 or not math.isfinite(load) or load < 0:
        return 'invalid temperature or load observation', False
    if value['free_bytes'] <= 100*(1 << 30):
        return 'free disk must exceed 100 GiB', False
    if temperature > 42 or load > 4:
        return 'GPU temperature exceeds 42 C or load1 exceeds 4', True
    return None, False


def require_entry(value):
    reason, _ = entry_refusal(value)
    if reason is not None:
        raise ValueError('host not ready for measured entry: '+reason)


def report_observation(value):
    # JSON cannot encode nonfinite measurements. Keep their exact classification
    # beside null numeric fields; invalid measurements still refuse entry.
    result = dict(value)
    errors = {key: repr(value[key]) for key in ('gpu_temperature_c', 'load1')
              if not math.isfinite(value[key])}
    if errors:
        result['measurement_errors'] = errors
        for key in errors:
            result[key] = None
    return result


def wait_for_entry(target, checkpoint, emit, record, interval=2):
    """Only transient heat/load may wait; ownership/identity/disk fail closed."""
    while True:
        checkpoint()
        observation = observe(target)
        reason, retryable = entry_refusal(observation)
        if (observation['hardware_model'] != target['hardware_model']
                or observation['memory_bytes'] != target['memory_bytes']):
            reason, retryable = 'host hardware identity differs', False
        reported = report_observation(observation)
        record['entry_observation'] = reported
        record['entry_reason'] = reason
        emit({'event': 'entry', 'fixture_pid': os.getpid(), 'observation': reported,
              'entry_ready': reason is None, 'entry_reason': reason, 'retryable': retryable})
        checkpoint()  # EOF/stop during telemetry must prevent launch even if ready.
        if reason is None:
            return observation
        if not retryable:
            raise ValueError('host not ready for measured entry: '+reason)
        checkpoint(interval)


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


def verify_models(target, home, checkpoint=None):
    for model in target['models']:
        snapshot = Path(model['snapshot']).resolve(strict=True)
        for name, row in model['files'].items():
            check_file(model_file(snapshot, name), row, checkpoint)
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


def prepare(request, checkpoint=None, emit=lambda value: None, record=None, created=lambda root: None):
    target, spec = request['target'], request['spec']
    record = {} if record is None else record
    if checkpoint is None:
        deadline = time.monotonic()+300
        def checkpoint(wait=0):
            if time.monotonic()+wait >= deadline:
                raise TimeoutError('owned host prelaunch deadline expired')
            time.sleep(wait)
    checkpoint()
    home = Path.home()
    root = canonical_owned_root(target['root'], home)
    if spec['root'] != target['root']:
        raise ValueError('launch root differs from target')
    canonical = home/'.config/darkbloom/provider.toml'
    if digest(canonical, checkpoint) != target['canonical_config_sha256']:
        raise ValueError('canonical config differs; no repair performed')
    for relative in ('.darkbloom/telemetry-queue.jsonl', '.darkbloom/telemetry-queue.jsonl.tmp'):
        path = home/relative
        if path.exists() or path.is_symlink():
            raise ValueError('retired startup artifact exists; no deletion performed')
    runtime = Path(target['runtime_directory']).resolve(strict=True)
    if root == runtime or root in runtime.parents or runtime in root.parents:
        raise ValueError('owned root overlaps source runtime')
    for name, row in target['runtime_files'].items():
        check_file(safe_file(runtime, name), row, checkpoint)
    entitlement = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(runtime/'darkbloom')],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    if entitlement.returncode != 0 or b'keychain-access-groups' in entitlement.stdout:
        raise ValueError('verifiably unentitled fixture runtime required')
    for model in target['models']:
        snapshot = Path(model['snapshot']).resolve(strict=True)
        if root == snapshot or root in snapshot.parents or snapshot in root.parents:
            raise ValueError('owned root overlaps selected model input')
    verify_models(target, home, checkpoint)
    wait_for_entry(target, checkpoint, emit, record)
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
    checkpoint()
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGHUP, signal.SIGTERM, signal.SIGINT))
    try:
        root.mkdir(mode=0o700)
        created(root)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    (root/'runtime').mkdir(mode=0o700)
    for name, row in target['runtime_files'].items():
        destination = root/'runtime'/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        checkpoint()
        shutil.copy2(runtime/name, destination)
        check_file(destination, row, checkpoint)
    (root/'tmp').mkdir(mode=0o700)
    for name, raw in (('provider.toml', spec['config'].encode()), ('auth_token', token)):
        checkpoint()
        descriptor = os.open(root/name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(raw)
    observation = wait_for_entry(target, checkpoint, emit, record)
    if digest(canonical, checkpoint) != target['canonical_config_sha256']:
        raise ValueError('canonical config differs before launch; no repair performed')
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
            # The group may exit between the presence check and the signal.
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


def run_owner(command, environment, root, control, emit, lease_seconds=30, deadline_seconds=1800,
              observation=None, prepare_launch=None, initial_control=b'', prelaunch_seconds=300):
    """Own preparation and one child group under the same control pipe and lease."""
    selector = selectors.DefaultSelector()
    selector.register(control, selectors.EVENT_READ)
    process = None
    launch = {'command': command, 'environment': environment, 'root': root}
    record = {'event': 'terminal', 'fixture_pid': os.getpid(), 'provider_started': False,
              'pid': None, 'exit_code': None, 'failure': None, 'stop_requested': False,
              'group_cleanup_complete': True}
    signals = (signal.SIGHUP, signal.SIGTERM, signal.SIGINT)
    old_handlers = {sig: signal.getsignal(sig) for sig in signals}
    class OwnerInterrupted(Exception):
        pass
    class OwnerStopped(Exception):
        pass
    def interrupted(signum, _frame):
        for sig in signals:
            signal.signal(sig, signal.SIG_IGN)
        raise OwnerInterrupted('owner signal '+str(signum))
    for sig in signals:
        signal.signal(sig, interrupted)
    start = last_control = time.monotonic()
    provider_start = None
    pending = initial_control

    def checkpoint(wait=0):
        nonlocal pending, last_control
        until = time.monotonic()+wait
        while True:
            now = time.monotonic()
            if process is None and now-start >= prelaunch_seconds:
                raise TimeoutError('owned host prelaunch deadline expired')
            if provider_start is not None and now-provider_start >= deadline_seconds:
                raise TimeoutError('owned process deadline expired')
            if now-last_control >= lease_seconds:
                raise TimeoutError('controller lease expired')
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                message = json.loads(line)
                last_control = time.monotonic()
                kind = message.get('command')
                if kind == 'stop':
                    raise OwnerStopped()
                if kind == 'ping':
                    continue
                request_id = message.get('id')
                if not isinstance(request_id, int) or isinstance(request_id, bool) or request_id <= 0:
                    raise ValueError('positive control request identity required')
                if kind == 'observe' and observation is not None:
                    emit({'event': 'observation', 'id': request_id,
                          'observation': observation(None if process is None else process.pid)})
                    continue
                if kind != 'state':
                    raise ValueError('unknown controller operation')
                if process is None:
                    emit({'event': 'state', 'id': request_id, 'error': 'not_ready', 'retryable': True})
                    continue
                path = launch['root']/'daemon-state.json'
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
            if not selector.select(max(0, min(0.25, until-time.monotonic()))):
                if time.monotonic() >= until:
                    return
                continue
            chunk = os.read(control.fileno(), 4096)
            if not chunk:
                raise OwnerInterrupted('controller pipe EOF')
            pending += chunk
            if len(pending) > MAX_CONTROL:
                raise ValueError('control frame exceeds limit')

    try:
        checkpoint()
        if prepare_launch is not None:
            prepare_launch(checkpoint, launch, record)
        checkpoint()
        while pending:  # Never launch while a pre-start control frame is incomplete.
            checkpoint(0.25)
        with (launch['root']/'provider.log').open('xb') as log:
            checkpoint()
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
            try:
                process = subprocess.Popen(launch['command'], env=launch['environment'], stdout=log,
                    stderr=log, start_new_session=True,
                    preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask))
                record['pid'] = process.pid
                record['provider_started'] = True
                provider_start = time.monotonic()
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            emit({'event': 'started', 'fixture_pid': os.getpid(), 'pid': process.pid, 'pgid': process.pid})
            while process.poll() is None:
                checkpoint(0.25)
    except OwnerStopped:
        record['stop_requested'] = True
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
            record['root_created'] = launch['root'] is not None
            if launch['root'] is not None:
                (launch['root']/'terminal.json').write_text(json.dumps(record, indent=2, allow_nan=False)+'\n')
            try:
                emit(record)
            except (BrokenPipeError, OSError):
                # The caller may have closed its reader during teardown.
                pass
        finally:
            selector.close()
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
    return record


def initial_request(control):
    pending = b''
    while b'\n' not in pending:
        chunk = os.read(control.fileno(), 4096)
        if not chunk or len(pending)+len(chunk) > MAX_CONTROL:
            raise ValueError('bounded initial control frame required')
        pending += chunk
    first, pending = pending.split(b'\n', 1)
    return json.loads(first), pending


def retire_owned_credential(root, record):
    """Retire only this fixture's credential once its own group is confirmed gone."""
    result = {'auth_token_retired': False, 'error': None,
              'provider_pid': record.get('pid'),
              'provider_group_cleanup_complete': record.get('group_cleanup_complete') is True}
    if root is None:
        result['auth_token_retired'] = True  # No owned root/token was created.
        return result
    if not result['provider_group_cleanup_complete']:
        result['error'] = 'owned provider group retirement is unconfirmed'
    else:
        try:
            directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                try:
                    info = os.stat('auth_token', dir_fd=directory, follow_symlinks=False)
                except FileNotFoundError:
                    info = None
                if info is not None:
                    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                        raise ValueError('owned credential identity differs')
                    os.unlink('auth_token', dir_fd=directory)
                result['auth_token_retired'] = True
            finally:
                os.close(directory)
        except Exception as error:
            result['error'] = type(error).__name__+': '+str(error)
    # This separate receipt survives a later foreign-process/telemetry refusal.
    descriptor = os.open(root/'credential-retirement.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(json.dumps(result, indent=2, allow_nan=False)+'\n')
    return result


def finish_owner(request, owned, record, emit=send):
    credential = retire_owned_credential(owned.get('root'), record)
    canonical = Path.home()/'.config/darkbloom/provider.toml'
    if digest(canonical) != request['target']['canonical_config_sha256']:
        raise ValueError('canonical config changed; no repair performed')
    cleanup = observe(request['target'])
    emit({'event': 'cleanup', 'fixture_pid': os.getpid(), 'provider_started': record['provider_started'],
          'auth_token_retired': credential['auth_token_retired'],
          'auth_token_retirement_error': credential['error'],
          'observation': report_observation(cleanup)})
    if cleanup['unexpected_processes'] or cleanup['owned_processes']:
        raise ValueError('process leftovers after owned shutdown')
    if not credential['auth_token_retired'] or credential['error'] is not None:
        raise RuntimeError(credential['error'] or 'owned credential retirement unconfirmed')
    if record['failure'] is not None or (record['exit_code'] != 0 and not record['stop_requested']):
        raise RuntimeError(record['failure'] or 'provider exited without requested shutdown')


def main():
    request, pending = initial_request(sys.stdin.buffer)
    owned = {}
    def prepare_launch(checkpoint, launch, record):
        def created(root):
            launch['root'] = owned['root'] = root
        root, canonical, host_id, observation = prepare(request, checkpoint, send, record, created)
        send({'event': 'prepared', 'fixture_pid': os.getpid(), 'host_id': host_id,
              'observation': observation, 'root': str(root)})
        spec = request['spec']
        environment = {'HOME': str(Path.home()), 'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'}
        environment.update(spec['environment'])
        environment['DARKBLOOM_AUTH_TOKEN_PATH'] = str(root/'auth_token')
        launch.update(command=[str(root/'runtime/darkbloom')]+spec['arguments'], environment=environment)
    record = run_owner(None, None, None, sys.stdin.buffer, send, prepare_launch=prepare_launch,
        initial_control=pending, observation=lambda pid: observe(request['target'], () if pid is None else (pid,)))
    finish_owner(request, owned, record)


if __name__ == '__main__':
    main()
