"""Fixed per-host preparation/install/restore; run only by the reviewed outer driver."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
from configuration_files import digest, directory, executable_hash, locked, publish, read_private

ROOT = Path('/Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915')
HOME_DIRECTORY = Path('/Users/gaj')
PROVIDER = HOME_DIRECTORY / '.config/darkbloom/provider.toml'
DEVICE = HOME_DIRECTORY / '.darkbloom/cluster-device/native-device.lease'
CAPABILITY = '7e8a1480f1c8831cf447fa2f51935bf5e3b79024b1b83c09aa2df0bb6df883e7'
PROVIDER_BINARY = 'c4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350'
EXPECTED = {
    'darkbloom-24': ('leader', 'dea0e291200e111d0fbc5f8e549db5054546aeeaf963a854519804e3c5c675d6',
                    '7f2a82af486b2b58ed17a620b51e8ceceaf187e7a1f781f91d36bf1aa9a9c536'),
    'darkbloom-48': ('follower', '47c083ac6eb0d7926b4bd468437e3d6dea1dc92e9bc44e63a133c4cc907f941e',
                    '8d895c8217ea0896e406069faa92770bbe6d651d7ea4de8c866274fde4df967c'),
}


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def require_idle():
    raw = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True, timeout=5)
    active = [line.strip() for line in raw.splitlines() if len(line.split(maxsplit=1)) == 2
              and Path(line.split(maxsplit=1)[1]).name in
              ('darkbloom', 'darkbloom-cluster-worker', 'darkbloom-owner-qualification')]
    if active: raise ValueError('Product/native processes still exist')
    journal, _ = read_private(DEVICE)
    if journal: raise ValueError('Native device journal is nonempty')


def prepare(transaction, request, expected):
    role, original_hash, selected_hash = expected
    raw = base64.b64decode(request['configuration'], validate=True)
    if len(raw) > 65536 or digest(raw) != selected_hash:
        raise ValueError('Derived two-second configuration differs')
    require_idle()
    original, mode = read_private(PROVIDER)
    if digest(original) != original_hash or mode != 0o600:
        raise ValueError('Default provider preimage differs from installed binding')
    # Check the installed executable before asking it to parse/serialize TOML.
    if executable_hash(ROOT / 'darkbloom') != PROVIDER_BINARY:
        raise ValueError('Installed Provider binary differs')
    capability = HOME_DIRECTORY / '.config/darkbloom/clusters' / (CAPABILITY + '.capability.json')
    cap, _ = read_private(capability)
    if digest(cap) != CAPABILITY: raise ValueError('Installed capability differs')
    transaction.parent.mkdir(mode=0o700, exist_ok=True)
    with directory(transaction.parent): pass
    transaction.mkdir(mode=0o700)
    publish(transaction / 'provider.before.toml', original)
    publish(transaction / 'provider.after.toml', original)
    publish(transaction / 'configure.json', raw)
    # Existing CLI validates trust, canonical capability and profile, and uses
    # the real device/configuration locks. This does not change the default.
    command = [str(ROOT / 'darkbloom'), 'cluster', 'configure', '--input', str(transaction / 'configure.json'),
               '--capability', str(capability), '--capability-sha256', CAPABILITY,
               '--config', str(transaction / 'provider.after.toml'), '--json']
    result = subprocess.run(command, capture_output=True, timeout=30)
    if len(result.stdout) > 65536 or len(result.stderr) > 16384:
        raise ValueError('Configure output exceeded bound')
    publish(transaction / 'configure.stdout', result.stdout)
    publish(transaction / 'configure.stderr', result.stderr)
    if result.returncode != 0: raise ValueError('Staged configure refused')
    receipt = json.loads(result.stdout)
    if (receipt['configurationSHA256'] != selected_hash or receipt['capabilitySHA256'] != CAPABILITY
            or receipt['distributedEnabled'] is not False or receipt['readinessVerified'] is not False):
        raise ValueError('Staged configure binding differs')
    after, after_mode = read_private(transaction / 'provider.after.toml')
    current, current_mode = read_private(PROVIDER)
    if current != original or current_mode != mode or after_mode != mode:
        raise ValueError('Default changed during staging')
    state = dict(memberID=request['host'], attempt=request['attempt'], role=role,
                 providerPath=str(PROVIDER), beforeSHA256=original_hash, afterSHA256=digest(after),
                 mode=mode, configurationSHA256=selected_hash, defaultChanged=False)
    publish(transaction / 'state.json', encoded(state))
    return state


def swap(transaction, request, expected, restore):
    _, original_hash, selected_hash = expected
    require_idle()
    state_path = transaction / 'state.json'
    if request['postimageSHA256'] is None:
        # A refused prepare never mutates the default. Still verify the exact
        # original bytes; do not infer restoration from a missing receipt.
        if not restore: raise ValueError('Prepared transaction missing')
        raw, mode = read_private(PROVIDER)
        if digest(raw) != original_hash or mode != 0o600:
            raise ValueError('Unprepared transaction cannot restore unknown bytes')
        return dict(restored=True, providerSHA256=original_hash, mode=mode, noSwapRequired=True)
    state = json.loads(read_private(state_path)[0])
    if (state['beforeSHA256'] != original_hash or state['configurationSHA256'] != selected_hash
            or state['memberID'] != request['host'] or state['attempt'] != request['attempt']
            or state['providerPath'] != str(PROVIDER) or state['mode'] != 0o600
            or state['afterSHA256'] != request['postimageSHA256']):
        raise ValueError('Durable transaction binding differs')
    before, _ = read_private(transaction / 'provider.before.toml')
    after, _ = read_private(transaction / 'provider.after.toml')
    if digest(before) != original_hash or digest(after) != state['afterSHA256']:
        raise ValueError('Durable pre/postimage differs')
    desired, expected_current = (before, state['afterSHA256']) if restore else (after, original_hash)
    with locked(DEVICE, require_empty=True), locked(PROVIDER.with_name(PROVIDER.name + '.lock')):
        require_idle()
        current, mode = read_private(PROVIDER)
        if mode != state['mode']: raise ValueError('Default provider mode changed')
        if digest(current) != digest(desired):
            publish(PROVIDER, desired, mode=mode, expected=expected_current)
        current, mode = read_private(PROVIDER)
        if current != desired or mode != state['mode']: raise ValueError('Default verification failed')
    return dict(restored=restore, installed=not restore, providerSHA256=digest(current),
                mode=mode, configurationSHA256=selected_hash if not restore else None)


def execute(request):
    if (set(request) != {'action', 'host', 'attempt', 'configuration', 'postimageSHA256'}
            or request['host'] not in EXPECTED or type(request['attempt']) is not int
            or not 1 <= request['attempt'] <= 99 or request['action'] not in ('prepare', 'install', 'restore')):
        raise ValueError('Invalid fixed configuration transaction')
    pin = request['postimageSHA256']
    if pin is not None and (type(pin) is not str or len(pin) != 64 or any(c not in '0123456789abcdef' for c in pin)):
        raise ValueError('Invalid postimage pin')
    if request['action'] == 'prepare' and pin is not None:
        raise ValueError('Preparation cannot adopt an old transaction')
    transaction = ROOT / 'configuration-transactions' / ('configured-deadline-' + str(request['attempt']))
    if request['action'] == 'prepare':
        return prepare(transaction, request, EXPECTED[request['host']])
    return swap(transaction, request, EXPECTED[request['host']], request['action'] == 'restore')


if __name__ == '__main__':
    try:
        raw = sys.stdin.buffer.read(131073)
        if len(raw) > 131072: raise ValueError('Transaction input exceeded bound')
        print(json.dumps(execute(json.loads(raw)), sort_keys=True))
    except BaseException as error:
        print(json.dumps({'error': type(error).__name__ + ': ' + str(error)}))
        sys.exit(1)
