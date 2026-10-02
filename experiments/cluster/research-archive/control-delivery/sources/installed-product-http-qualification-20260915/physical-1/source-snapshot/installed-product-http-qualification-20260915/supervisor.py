"""Own one real product process; stdin EOF/stop cancels it, never unrelated PIDs."""
from pathlib import Path
import json, os, select, signal, subprocess, sys, time

root = Path('/Users/developer/DarkbloomDev/installed-distributed-runtime-20260915')
run = Path(sys.argv[1])
assert run.parent == root / 'qualification'
run.parent.mkdir(mode=0o700, exist_ok=True)
run.mkdir(mode=0o700)
command = [str(root / 'darkbloom'), 'start', '--local', '--distributed',
           '--bind', '192.0.2.250', '--port', '18081']
started = time.monotonic()
result = {'schema': 'installed_product_supervisor_v1', 'command': command,
          'startedUnix': time.time(), 'forcedKill': False}
with (run / 'provider.stdout').open('xb') as out, (run / 'provider.stderr').open('xb') as err:
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err)
    result['pid'] = process.pid
    print(json.dumps({'state': 'started', 'pid': process.pid}), flush=True)
    reason = 'natural-exit'
    try:
        while process.poll() is None:
            if time.monotonic() - started > 325:
                reason = 'supervisor-deadline'; break
            if select.select([sys.stdin], [], [], 0.1)[0]:
                line = sys.stdin.readline()
                reason = 'requested-stop' if line == 'stop\n' else 'control-eof-or-invalid'
                break
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=22)
            except subprocess.TimeoutExpired:
                result['forcedKill'] = True
                process.kill(); process.wait(timeout=5)
        result.update(exitCode=process.returncode, stopReason=reason,
                      elapsedSeconds=time.monotonic()-started)
(run / 'supervisor.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'state': 'exited', **result}), flush=True)
sys.exit(0 if process.returncode == 0 and not result['forcedKill'] else 1)
