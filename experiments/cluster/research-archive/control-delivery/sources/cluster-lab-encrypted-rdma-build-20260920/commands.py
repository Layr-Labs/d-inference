"""One bounded owned child at a time; exact previously reviewed cleanup helper."""
import time

from guards import pin, save_receipt
from owned_process import invoke_controller


def run(output, receipt, name, argv, timeout, expected_exit=0, output_limit=64 * 1024 * 1024):
    row = dict(name=name, argv=argv, expectedExitCode=expected_exit)
    receipt.setdefault('steps', []).append(row)
    started = time.monotonic()
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            invoke_controller(argv, stdout, stderr, row, timeout=timeout)
    finally:
        row['elapsedSeconds'] = time.monotonic() - started
        for stream in ('stdout', 'stderr'):
            path = output / (name + '.' + stream)
            if path.exists():
                row[stream] = pin(path)
        save_receipt(output / 'receipt.json', receipt)
    if row.get('exitCode') != expected_exit or not row.get('reaped') or not row.get('groupAbsent') or row.get('failure'):
        raise ValueError('Owned child did not retire with its expected exit: ' + name)
    if any(row[stream]['bytes'] > output_limit for stream in ('stdout', 'stderr')):
        raise ValueError('Retained child output exceeds the accepted bound: ' + name)
    return row
