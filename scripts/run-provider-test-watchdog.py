#!/usr/bin/env python3
"""Run provider tests with a hard deadline and retain stalled Swift stacks."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def owned_processes(root_pid):
    rows = []
    output = subprocess.check_output(
        ['ps', '-axo', 'pid=,ppid=,pgid=,stat=,comm='], text=True, timeout=5)
    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) == 5:
            rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]), pgid=int(parts[2]),
                             state=parts[3], executable=Path(parts[4]).name))
    owned = {root_pid}
    for row in rows:
        try:
            if os.getsid(row['pid']) == root_pid:
                owned.add(row['pid'])
        except OSError:
            # A process may exit or deny inspection between ps and getsid.
            # The ancestry walk still finds accessible descendants.
            pass
    while True:
        expanded = owned | {r['pid'] for r in rows if r['ppid'] in owned}
        if expanded == owned:
            return [r for r in rows if r['pid'] in owned]
        owned = expanded


def diagnose(root_pid, output_dir):
    try:
        rows = owned_processes(root_pid)
        (output_dir / 'processes.json').write_text(json.dumps(rows, indent=2) + '\n')
        if sys.platform == 'darwin':
            for row in rows:
                if not any(name in row['executable'] for name in ('swift', 'xctest', 'PackageTests')):
                    continue
                try:
                    subprocess.run(
                        ['/usr/bin/sample', str(row['pid']), '1', '10', '-file',
                         str(output_dir / f"sample-{row['pid']}.txt")],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
                except subprocess.TimeoutExpired:
                    # A slow symbolicator must not hang diagnostic collection.
                    pass
    except Exception as error:
        (output_dir / 'diagnostic-error.txt').write_text(str(error) + '\n')


def stop_owned(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        process.poll()  # Reap an exited leader before considering its group.
        try:
            groups = {r['pgid'] for r in owned_processes(process.pid)
                      if not r['state'].startswith('Z')}
        except Exception:
            groups = {process.pid} if process.poll() is None else set()
        groups.discard(os.getpgrp())
        for group in groups:
            try:
                os.killpg(group, sig)
            except ProcessLookupError:
                # The group may exit between enumeration and killpg.
                pass
            except PermissionError:
                # macOS can report EPERM when the last member exits between
                # enumeration and killpg; do not swallow a live-group refusal.
                if any(r['pgid'] == group and not r['state'].startswith('Z')
                       for r in owned_processes(process.pid)):
                    raise
        if sig == signal.SIGTERM and groups:
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--diagnostic-after-seconds', type=float, default=480)
    parser.add_argument('--timeout-seconds', type=float, default=900)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not 0 <= args.diagnostic_after_seconds < args.timeout_seconds:
        parser.error('provide a command and 0 <= diagnostic delay < timeout')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, NSUnbufferedIO='YES')
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True, env=env)
    interrupted = []
    stop = threading.Event()

    def on_signal(signum, _frame):
        interrupted.append(signum)
        stop.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, on_signal)

    def forward_output():
        with (args.output_dir / 'test-output.log').open('wb', buffering=0) as log:
            while chunk := os.read(process.stdout.fileno(), 8192):
                log.write(chunk)
                try:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                except BrokenPipeError:
                    # Preserve the file transcript if the CI console closes.
                    pass

    reader = threading.Thread(target=forward_output, daemon=True)
    reader.start()
    started = time.monotonic()
    diagnosed = timed_out = False
    try:
        while process.poll() is None and not interrupted:
            elapsed = time.monotonic() - started
            if not diagnosed and elapsed >= args.diagnostic_after_seconds:
                diagnose(process.pid, args.output_dir)
                diagnosed = True
            if elapsed >= args.timeout_seconds:
                timed_out = True
                break
            stop.wait(0.1)
        if timed_out or interrupted:
            if not diagnosed:
                diagnose(process.pid, args.output_dir)
            stop_owned(process)
        code = process.wait()
        reader.join(timeout=5)
        result = dict(exit_code=code, timed_out=timed_out, interrupted=interrupted,
                      elapsed_seconds=round(time.monotonic() - started, 3))
        (args.output_dir / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        if timed_out:
            print('::error::Provider tests exceeded their deadline; retained diagnostics identify the stalled process.', file=sys.stderr)
            return 124
        if interrupted:
            return 128 + interrupted[0]
        return code if code >= 0 else 128 - code
    finally:
        if process.poll() is None:
            stop_owned(process)
            process.wait()


if __name__ == '__main__':
    sys.exit(main())
