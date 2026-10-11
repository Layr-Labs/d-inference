"""Root-supervised, unprivileged execution of the two static candidate commands."""
import argparse
import base64
import json
import os
from pathlib import Path
import pwd
import resource
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

MAX_OUTPUT_BYTES = 1 << 20
COMMAND_TIMEOUT = 180
ROOT_PREFIX = 'darkbloom-static-'


def sandbox_policy(root):
    app = json.dumps(str(root / 'Darkbloom.app'))
    home = json.dumps(str(root / 'home'))
    executable = json.dumps(str(root / 'Darkbloom.app/Contents/MacOS/darkbloom'))
    directory = json.dumps(str(root))
    return f'''(version 1)
(deny default)
(allow process-exec (literal {executable}))
(deny process-fork)
(deny process-info*)
(deny network*)
(allow file-read-metadata (literal "/") (literal "/private") (literal "/private/tmp")
    (literal {directory}) (literal "/usr") (literal "/Library") (literal "/dev")
    (literal "/private/var") (literal "/private/var/db") (literal "/private/etc"))
(allow file-read* (literal "/") (subpath {app}) (subpath {home})
    (subpath "/System") (subpath "/usr/lib") (subpath "/Library/Apple")
    (subpath "/private/var/db/dyld")
    (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom")
    (literal "/private/etc/localtime"))
(allow file-write* (subpath {home}) (literal "/dev/null"))
(allow sysctl-read (sysctl-name-regex #"^hw\\.")
    (sysctl-name "kern.osrelease") (sysctl-name "kern.osversion"))
(allow mach-lookup
    (global-name "com.apple.MTLCompilerService")
    (global-name "com.apple.MetalCompilerService")
    (global-name "com.apple.CARenderServer")
    (global-name "com.apple.windowserver.active")
    (global-name "com.apple.cfprefsd.agent")
    (global-name "com.apple.cfprefsd.daemon"))
(allow iokit-open (iokit-user-client-class-regex #"^(AGX|IOGPU|IOSurface)"))
'''


def validate_root(root):
    root = Path(root)
    if (root.parent != Path('/private/tmp') or not root.name.startswith(ROOT_PREFIX) or
            len(root.name) <= len(ROOT_PREFIX)):
        raise ValueError('Invalid candidate isolation root')
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('Candidate isolation root is not root-owned and protected')
    return root


def prepare(source):
    nobody = pwd.getpwnam('nobody')
    if nobody.pw_uid <= 0 or nobody.pw_gid <= 0:
        raise ValueError('Missing unprivileged nobody identity')
    root = Path(tempfile.mkdtemp(prefix=ROOT_PREFIX, dir='/private/tmp'))
    try:
        app = root / 'Darkbloom.app'
        subprocess.run(['/usr/bin/ditto', '--extattr', '--noacl', str(source), str(app)],
                       check=True, capture_output=True, timeout=60)
        for path in [app, *app.rglob('*')]:
            info = path.lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError('Isolation copy contains a link or special file')
            os.chown(path, 0, 0)
            # Never promote archived setuid/setgid bits into root privilege.
            os.chmod(path, 0o555 if stat.S_ISDIR(info.st_mode) or info.st_mode & 0o111 else 0o444)
        home = root / 'home'
        home.mkdir(mode=0o700)
        (home / 'tmp').mkdir(mode=0o700)
        os.chown(home, nobody.pw_uid, nobody.pw_gid)
        os.chown(home / 'tmp', nobody.pw_uid, nobody.pw_gid)
        (root / 'policy.sb').write_text(sandbox_policy(root))
        os.chmod(root / 'policy.sb', 0o444)
        shutil.copyfile(__file__, root / 'supervisor.py')
        os.chmod(root / 'supervisor.py', 0o400)
        os.chmod(root, 0o755)
        return root
    except BaseException:
        shutil.rmtree(root)
        raise


def supervise(root, command):
    root = validate_root(root)
    nobody = pwd.getpwnam('nobody')
    if nobody.pw_uid <= 0 or nobody.pw_gid <= 0:
        raise ValueError('Missing unprivileged nobody identity')
    app = root / 'Darkbloom.app'
    for path in [app, *app.rglob('*'), root / 'policy.sb', root / 'supervisor.py']:
        info = path.lstat()
        if (info.st_uid != 0 or info.st_mode & 0o222 or
                not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))):
            raise ValueError('Candidate execution files are mutable or not root-owned')
    home = root / 'home'
    env = {'HOME': str(home), 'TMPDIR': str(home / 'tmp'), 'CFFIXED_USER_HOME': str(home),
           'USER': 'nobody', 'LOGNAME': 'nobody', 'PATH': '/usr/bin:/bin', 'LANG': 'C',
           'DARKBLOOM_NO_UPDATE_CHECK': '1', 'DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL': '18',
           'MLX_GEMMA4_FUSED_WEIGHTED_UNSORT': '1', 'MLX_GATHER_QMM_EXPERT_SLICES': '1'}

    def unprivileged():
        os.setgroups([])
        os.setgid(nobody.pw_gid)
        os.setuid(nobody.pw_uid)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_FSIZE, (64 << 20, 64 << 20))
        resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
        resource.setrlimit(resource.RLIMIT_NPROC, (1, 1))
        resource.setrlimit(resource.RLIMIT_CPU, (120, 130))

    args = ['/usr/bin/sandbox-exec', '-f', str(root / 'policy.sb'),
            str(app / 'Contents/MacOS/darkbloom'), command]
    process = subprocess.Popen(args, cwd=home, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, preexec_fn=unprivileged)
    output = {'stdout': bytearray(), 'stderr': bytearray()}
    deadline = time.monotonic() + COMMAND_TIMEOUT

    def interrupted(signum, frame):
        raise RuntimeError('Isolated candidate supervisor interrupted')

    old_handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        with selectors.DefaultSelector() as poller:
            for label, stream in [('stdout', process.stdout), ('stderr', process.stderr)]:
                poller.register(stream, selectors.EVENT_READ, label)
            while poller.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('Isolated candidate exceeded time limit')
                for key, _ in poller.select(min(remaining, 0.25)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        poller.unregister(key.fileobj)
                        continue
                    output[key.data].extend(chunk)
                    if sum(len(value) for value in output.values()) > MAX_OUTPUT_BYTES:
                        raise ValueError('Isolated candidate exceeded output limit')
        returncode = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        if returncode:
            raise ValueError(f'Isolated candidate failed ({returncode}); sandbox support is mandatory')
        return {key: base64.b64encode(value).decode('ascii') for key, value in output.items()}
    finally:
        # This group was created here, never discovered by UID or process name.
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()
        for sig, previous in old_handlers.items():
            signal.signal(sig, previous)


class IsolatedCandidate:
    def __init__(self, source):
        self.source = source
        self.root = None

    def _root_command(self, script, *args):
        # env -i and isolated Python keep Actions credentials out of root helpers.
        return subprocess.run(['/usr/bin/sudo', '-n', '--', '/usr/bin/env', '-i',
                               'PATH=/usr/bin:/bin', sys.executable, '-I', str(script), *args],
                              capture_output=True, check=True, timeout=COMMAND_TIMEOUT + 30,
                              env={'PATH': '/usr/bin:/bin'})

    def __enter__(self):
        if os.geteuid() == pwd.getpwnam('nobody').pw_uid:
            raise ValueError('The checker cannot share the candidate UID')
        result = self._root_command(Path(__file__).resolve(), 'prepare', str(self.source))
        self.root = validate_root(Path(result.stdout.decode().strip()))
        return self

    def run(self, command):
        if command not in ('--version', 'runtime-smoke'):
            raise ValueError('Only static qualification commands may execute')
        result = self._root_command(self.root / 'supervisor.py', 'run', str(self.root), '--', command)
        output = json.loads(result.stdout)
        return subprocess.CompletedProcess([str(self.root / 'Darkbloom.app/Contents/MacOS/darkbloom'), command],
                                           0, base64.b64decode(output['stdout'], validate=True),
                                           base64.b64decode(output['stderr'], validate=True))

    def __exit__(self, exc_type, exc_value, traceback):
        self._root_command(self.root / 'supervisor.py', 'cleanup', str(self.root))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'run', 'cleanup'])
    parser.add_argument('path', type=Path)
    parser.add_argument('command', nargs='?', choices=['--version', 'runtime-smoke'])
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Isolation supervisor requires root')
    if args.action == 'prepare':
        print(prepare(args.path))
    elif args.action == 'run':
        if args.command is None:
            raise ValueError('Missing static candidate command')
        print(json.dumps(supervise(args.path, args.command)))
    else:
        shutil.rmtree(validate_root(args.path))


if __name__ == '__main__':
    main()
