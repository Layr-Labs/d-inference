"""Resource observations and the previously reviewed bounded alias lease."""
import json, os, queue, select, shlex, subprocess, threading, time

SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8']
REMOTE = '/Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915'

class Monitor:
    def __init__(self, host, rank, output):
        self.first = queue.Queue(maxsize=1)
        self.errors = []
        self.last = time.monotonic()
        self.closing = False
        self.out = (output / ('resources-' + str(rank) + '.jsonl')).open('xb')
        self.err = (output / ('resources-' + str(rank) + '.stderr')).open('xb')
        command = shlex.join(['/usr/bin/python3', '-B', REMOTE + '/qualification-tools/monitor.py'])
        self.process = subprocess.Popen(SSH + [host, command], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.err)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        try:
            count = 0
            while True:
                line = self.process.stdout.readline(65537)
                if not line: break
                self.out.write(line); self.out.flush()
                if len(line) > 65536 or not line.endswith(b'\n') or count >= 1400:
                    raise RuntimeError('Resource monitor output exceeded bound')
                record = json.loads(line); self.last = time.monotonic()
                if count == 0: self.first.put(record)
                if record.get('admissible') is not True:
                    self.errors.append('Inadmissible sample ' + str(count))
                count += 1
            if not self.closing:
                self.errors.append('Monitor ended before requested stop')
        except Exception as error:
            self.errors.append(type(error).__name__ + ': ' + str(error))
        finally:
            if self.first.empty():
                self.first.put({'admissible': False, 'error': 'No initial sample'})

    def require(self):
        if self.errors or time.monotonic() - self.last > 12:
            raise RuntimeError('Resource monitor failed or became stale: ' + '; '.join(self.errors))

    def stop(self):
        self.closing = True
        try:
            self.process.stdin.write(b'stop\n'); self.process.stdin.flush()
        except (OSError, BrokenPipeError): pass
        try: self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.errors.append('Monitor shutdown exceeded bound')
            self.process.kill(); self.process.wait(timeout=5)
        self.thread.join(timeout=5)
        if self.thread.is_alive(): self.errors.append('Monitor did not join')
        else: self.out.close()
        self.err.close()
        return {'exitCode': self.process.returncode, 'errors': self.errors}

class AliasLease:
    def __init__(self, lease_code, credentials, output):
        rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
                for line in credentials.read_text().splitlines() if line.startswith('|')]
        password = rows[2][[cell.lower() for cell in rows[0]].index('password')]
        connection = subprocess.run(SSH + ['darkbloom-48', '/usr/bin/printenv', 'SSH_CONNECTION'],
            capture_output=True, text=True, check=True, timeout=10)
        fields = connection.stdout.split()
        if len(fields) != 4 or ':' in fields[0]: raise RuntimeError('Management route shape differs')
        self.err = (output / 'lease.stderr').open('xb'); os.fchmod(self.err.fileno(), 0o600)
        self.process = subprocess.Popen(SSH + ['darkbloom-48', shlex.join([
            '/usr/bin/sudo', '-k', '-S', '-p', '', '/usr/bin/python3', '-c', lease_code, fields[0]])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, bufsize=0)
        self.process.stdin.write((password + '\n').encode()); self.process.stdin.flush()
        self.output = output

    def ready(self):
        line = bytearray(); until = time.monotonic() + 15
        while b'\n' not in line:
            if time.monotonic() >= until: raise RuntimeError('Alias readiness deadline exceeded')
            if not select.select([self.process.stdout], [], [], 0.25)[0]: continue
            block = os.read(self.process.stdout.fileno(), 1)
            if not block or len(line) > 65536: raise RuntimeError('Alias stream ended or exceeded bound')
            line.extend(block)
        value = json.loads(line)
        if value.get('state') != 'ready': raise RuntimeError('Alias was not admitted')
        return value

    def stop(self):
        try:
            self.process.stdin.write(b'release\n'); self.process.stdin.flush()
        except (OSError, BrokenPipeError): pass
        try:
            tail, _ = self.process.communicate(timeout=40)
            (self.output / 'lease.stdout.tail.jsonl').write_bytes(tail)
            values = [json.loads(line) for line in tail.splitlines() if line.strip()]
            return {'exitCode': self.process.returncode, 'final': values,
                    'restored': self.process.returncode == 0 and len(values) == 1 and values[0].get('restored') is True}
        finally: self.err.close()
