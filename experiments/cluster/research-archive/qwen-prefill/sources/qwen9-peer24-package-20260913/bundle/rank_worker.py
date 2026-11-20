"""Bounded rank supervisor; runs unchanged locally or over SSH."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from artifacts import file_sha256, verify_files, verify_model


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


def execute(config_path):
    config = json.loads(config_path.read_text())
    persistent = config.get('persistent', False)
    if type(persistent) is not bool:
        raise ValueError('persistent must be a boolean')
    directory = config_path.parent
    bundle = Path(config['bundle']).expanduser()
    manifest = bundle / 'bundle.json'
    if file_sha256(manifest) != config['bundle_sha256']:
        raise ValueError('Bundle manifest differs from the requested build')
    verify_files(bundle, json.loads(manifest.read_text())['files'])
    if config.get('model_directory'):
        verify_model(Path(config['model_directory']).expanduser(),
                     config['artifact_aggregate_sha256'])

    environment = os.environ.copy()
    for name in list(environment):
        if name.startswith(('MLX_', 'JACCL_', 'DARKBLOOM_')):
            del environment[name]
    environment.update(config['environment'])
    for name, content in config.get('input_files', {}).items():
        if Path(name).name != name:
            raise ValueError('Input files must be flat within the rank directory')
        (directory / name).write_text(json.dumps(content))
    for variable, name in config.get('environment_files', {}).items():
        environment[variable] = str(directory / name)

    arguments = config['arguments'][:]
    for index, value in enumerate(arguments):
        if value.startswith('@rank/'):
            arguments[index] = str(directory / value[len('@rank/'):])
        elif value == '@model':
            arguments[index] = str(Path(config['model_directory']).expanduser())
    child, status = None, 1
    # Persistent workers own startup/idle/request alarms. Their supervisor
    # remains alive across requests, while cancel files and signals still own
    # the entire native child group independently of the protocol client.
    deadline = None if persistent else time.monotonic() + config['timeout_seconds']
    try:
        child = subprocess.Popen([str(bundle / 'cluster-inference'), *arguments],
                                 cwd=directory, env=environment, start_new_session=True)
        while True:
            remaining = 0.1 if deadline is None else deadline - time.monotonic()
            if (directory / 'cancel').exists():
                status = 125
                break
            if remaining <= 0:
                status = 124
                break
            try:
                status = child.wait(timeout=min(0.1, remaining))
                break
            except subprocess.TimeoutExpired:
                pass
    finally:
        for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        if child is not None:
            # Descendants can outlive an already-exited session leader.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    return status if status >= 0 else 128 - status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    arguments = parser.parse_args()
    for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, terminate)
    try:
        return execute(arguments.config.resolve())
    except (ValueError, OSError, KeyError) as error:
        print(f'Rank supervisor: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
