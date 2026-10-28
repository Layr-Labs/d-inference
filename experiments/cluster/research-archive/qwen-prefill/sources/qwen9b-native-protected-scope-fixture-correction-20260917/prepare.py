"""Sixty-second root-owned preparation, with unchanged owned-child cleanup."""
import json
import os
from retry_inputs import BASE, inputs
from check_process import run_owned

if __name__ == '__main__':
    os.umask(0o077)
    inputs()
    output = BASE / 'prepare-command-3'
    output.mkdir(mode=0o700)
    result = run_owned(['/usr/bin/env', 'TMPDIR=/private/tmp/', 'python3', '-B',
        str(BASE / 'prepare_retry.py')], output, 'prepare', 60)
    print(json.dumps(result, sort_keys=True))
