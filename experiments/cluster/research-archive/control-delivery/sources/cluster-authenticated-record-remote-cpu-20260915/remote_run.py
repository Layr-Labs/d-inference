"""One create-only, guarded CPU benchmark. No model/native/RDMA operation."""
import base64
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys

ROOT = Path('/Users/developer/DarkbloomDev/cluster-record-cpu-benchmark-20260915')
JOURNAL = Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
BINARY = 'authenticated-record-benchmark'
BINARY_BYTES = 207408
BINARY_SHA = '3a2fb41e1374099700e19118458395828d262461e60e5daea060f155701602d8'
HELPER_SHA = '20ee93481bf65e4e0e8a34dd4ccb32835527a9955024a2c2898955a2e19fcebe'


def require(value, reason):
    if not value: raise RuntimeError(reason)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def directory(path):
    require(path.resolve() == path, 'Directory contains a symlink')
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) and stat.S_IMODE(value.st_mode) == 0o700
            and value.st_uid == os.getuid(), 'Unsafe private directory')
    return value


def regular(fd, size, mode):
    value = os.fstat(fd)
    require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid() and value.st_nlink == 1
            and stat.S_IMODE(value.st_mode) == mode and value.st_size == size, 'Unsafe regular file')
    return value


def bounded_read(fd, size, mode):
    before = regular(fd, size, mode); os.lseek(fd, 0, os.SEEK_SET)
    raw = bytearray()
    while len(raw) <= size:
        part = os.read(fd, min(65536, size + 1 - len(raw)))
        if not part: break
        raw.extend(part)
    require(len(raw) == size and identity(os.fstat(fd)) == identity(before), 'File changed or EOF differs')
    return bytes(raw), before


def no_live_processes():
    value = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True,
                           check=True, timeout=3)
    require(len(value.stdout.encode()) <= 1_048_576 and not value.stderr, 'Process observation failed')
    for line in value.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        require(len(fields) == 2 and fields[0].isdigit(), 'Malformed process observation')
        name = Path(fields[1]).name.lower()
        require(not name.startswith(('darkbloom', 'qwen'))
                and name not in {'cluster-inference', 'owner-controller'}, 'Existing owner/native/provider process')
    return {'prohibited': [], 'stdoutSHA256': hashlib.sha256(value.stdout.encode()).hexdigest()}


def main():
    raw = sys.stdin.buffer.read(524289)
    require(len(raw) <= 524288, 'CPU deployment packet too large')
    packet = json.loads(raw)
    require(set(packet) == {'schema', 'expectedSSHHost', 'binaryBase64', 'helperBase64'}
            and packet['schema'] == 'darkbloom_record_cpu_remote_v1'
            and packet['expectedSSHHost'] in ['darkbloom-24', 'darkbloom-48'], 'Wrong packet scope')
    binary = base64.b64decode(packet['binaryBase64'], validate=True)
    helper = base64.b64decode(packet['helperBase64'], validate=True)
    require(len(binary) == BINARY_BYTES and hashlib.sha256(binary).hexdigest() == BINARY_SHA, 'Wrong binary')
    require(len(helper) <= 8192 and hashlib.sha256(helper).hexdigest() == HELPER_SHA, 'Wrong owned helper')
    require(ROOT.parent.resolve() == ROOT.parent and ROOT.parent.is_dir(), 'Unsafe destination parent')
    journal_directory = directory(JOURNAL.parent)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    gate = os.open(JOURNAL, flags)
    root_fd = None; opened = []
    receipt = {'schema': 'darkbloom_record_cpu_remote_result_v1', 'expectedSSHHost': packet['expectedSSHHost'],
        'actualHostname': socket.gethostname(), 'binarySHA256': BINARY_SHA, 'root': str(ROOT),
        'modelExecuted': False, 'encryptedRDMAMeasured': False, 'journalModified': False, 'passed': False}
    def check_gate():
        require(identity(regular(gate, 0, 0o600)) == identity(gate_stat)
                and identity(JOURNAL.lstat()) == identity(gate_stat), 'Canonical journal changed')
        current = directory(JOURNAL.parent)
        require((current.st_dev, current.st_ino) == (journal_directory.st_dev, journal_directory.st_ino),
                'Canonical device directory changed')
    def check_root():
        current = directory(ROOT)
        require((current.st_dev, current.st_ino) == (root_stat.st_dev, root_stat.st_ino)
                and (os.fstat(root_fd).st_dev, os.fstat(root_fd).st_ino) == (root_stat.st_dev, root_stat.st_ino),
                'Private CPU directory changed')
    def verify_file(name, fd, data, mode):
        current, observed = bounded_read(fd, len(data), mode)
        require(current == data and identity(os.stat(name, dir_fd=root_fd, follow_symlinks=False)) == identity(observed),
                'Installed file bytes/identity differ')
        return hashlib.sha256(current).hexdigest()
    try:
        # Never create, truncate, resolve or replace the canonical journal.
        # Hold its existing empty exclusive FD throughout this short CPU child.
        fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
        gate_stat = regular(gate, 0, 0o600); check_gate()
        receipt['journalBefore'] = {'device': gate_stat.st_dev, 'inode': gate_stat.st_ino, 'bytes': 0}
        receipt['processesBefore'] = no_live_processes()
        require(not os.path.lexists(ROOT), 'Refuse existing CPU destination')
        ROOT.mkdir(mode=0o700); root_stat = directory(ROOT)
        root_fd = os.open(ROOT, flags | os.O_DIRECTORY); check_root()
        for name, content, mode in [(BINARY, binary, 0o700), ('owned_process.py', helper, 0o600)]:
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         mode, dir_fd=root_fd)
            opened.append(fd)
            view = memoryview(content)
            while view:
                count = os.write(fd, view); require(count > 0, 'Incomplete private write'); view = view[count:]
            os.fsync(fd); verify_file(name, fd, content, mode)
        os.fsync(root_fd)
        sys.path.insert(0, str(ROOT))
        from owned_process import invoke_controller
        child = {}
        try:
            check_gate(); check_root(); receipt['processesImmediatelyBefore'] = no_live_processes()
            receipt['binaryBeforeSHA256'] = verify_file(BINARY, opened[0], binary, 0o700)
            verify_file('owned_process.py', opened[1], helper, 0o600)
            streams = []
            try:
                for name in ['benchmark.stdout', 'benchmark.stderr']:
                    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 0o600, dir_fd=root_fd)
                    streams.append(os.fdopen(fd, 'wb'))
                launch_observation = io.StringIO()
                try:
                    with contextlib.redirect_stdout(launch_observation):
                        invoke_controller([str(ROOT / BINARY)], streams[0], streams[1], child,
                                          timeout=30, stdin=subprocess.DEVNULL)
                finally:
                    receipt['launchObservation'] = launch_observation.getvalue()
            finally:
                for stream in streams: stream.close()
        finally:
            # Child wait/kill/reap is entirely the exact reviewed helper. No
            # pre-existing PID or group is ever signalled by this parent.
            receipt['child'] = child
            check_gate(); check_root()
            receipt['processesAfter'] = no_live_processes()
            receipt['binaryAfterSHA256'] = verify_file(BINARY, opened[0], binary, 0o700)
            verify_file('owned_process.py', opened[1], helper, 0o600)
            receipt['journalAfter'] = {'device': gate_stat.st_dev, 'inode': gate_stat.st_ino, 'bytes': 0}
        require(len(receipt['launchObservation'].encode()) <= 1024, 'Unexpected launch observation')
        require(child.get('exitCode') == 0 and child.get('reaped') and child.get('groupAbsent')
                and not child.get('killedOwnedGroup'), 'CPU child did not end cleanly')
        captured = {}
        for name, limit in [('benchmark.stdout', 262144), ('benchmark.stderr', 65536)]:
            fd = os.open(name, flags, dir_fd=root_fd)
            try:
                size = os.fstat(fd).st_size; require(0 <= size <= limit, 'CPU output bound exceeded')
                content, observed = bounded_read(fd, size, 0o600)
                require(identity(os.stat(name, dir_fd=root_fd, follow_symlinks=False)) == identity(observed),
                        'CPU output path changed')
                captured[name] = content
            finally: os.close(fd)
        require(not captured['benchmark.stderr'], 'CPU child stderr is not empty')
        result = json.loads(captured['benchmark.stdout'])
        require(result['hostChip'] == 'Apple M4 Pro' and result['encryptedRDMAMeasured'] is False
                and result['modelMeasured'] is False, 'Unexpected actual CPU/scope')
        receipt.update(passed=True, report=result,
            stdoutSHA256=hashlib.sha256(captured['benchmark.stdout']).hexdigest(),
            stderrSHA256=hashlib.sha256(captured['benchmark.stderr']).hexdigest())
        output = (json.dumps(receipt, sort_keys=True) + '\n').encode()
        require(len(output) <= 393216, 'Remote result too large')
        fd = os.open('execution.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=root_fd)
        with os.fdopen(fd, 'wb') as stream: stream.write(output); stream.flush(); os.fsync(stream.fileno())
        check_gate(); check_root()
    finally:
        for fd in opened: os.close(fd)
        if root_fd is not None: os.close(root_fd)
        os.close(gate)
    sys.stdout.buffer.write(output); sys.stdout.buffer.flush()


if __name__ == '__main__': main()
