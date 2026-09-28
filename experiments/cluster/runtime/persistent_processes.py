"""Stage and launch persistent supervisors using the ordinary bundle contract."""

import json
from pathlib import Path
import shlex
import subprocess
import sys

from .bundle import snapshot
from .configuration import loopback_addresses
from .processes import scp, ssh_command, stage


REQUEST_FLAGS = {'--prompt-tokens', '--chunk-size', '--decode-tokens', '--warmups', '--repeats',
                 '--tokens-file', '--teacher-tokens-file', '--logits-file'}


def configure(rank, spec, epoch):
    path = Path(rank['local']) / 'rank.json'
    config = json.loads(path.read_text())
    arguments, filtered, index = config['arguments'], [], 0
    while index < len(arguments):
        flag = arguments[index]
        if flag in REQUEST_FLAGS:
            index += 2
            continue
        if flag == '--mode':
            filtered += [flag, 'worker' if spec['backend'] == 'solo' else 'worker-tp']
            index += 2
            continue
        filtered.append(flag)
        index += 1
    filtered += ['--epoch', epoch]
    config['arguments'], config['persistent'] = filtered, True
    for name in ('prompt.json', 'teacher.json'):
        config['input_files'].pop(name, None)
    path.write_text(json.dumps(config, indent=2) + '\n')
    path.chmod(0o600)
    if rank['host']:
        scp(str(path), f'{rank["host"]}:{shlex.quote(str(Path(rank["directory"]) / "rank.json"))}')


def prepare(spec, bundle, output, epoch, check_live):
    # Staging retains the existing independently bounded SSH and copy calls.
    digest = snapshot(bundle, output / 'bundle')
    hosts = loopback_addresses() if spec['backend'] == 'loopback-test' else None
    ranks = []
    for rank in range(len(spec['ranks'])):
        check_live()
        descriptor = stage(spec, rank, output, digest, hosts, epoch)
        configure(descriptor, spec, epoch)
        ranks.append(descriptor)
    check_live()
    return digest, ranks


def start(rank):
    command = [sys.executable if rank['host'] is None else '/usr/bin/python3',
               str(Path(rank['bundle']) / 'rank_worker.py'), str(Path(rank['directory']) / 'rank.json')]
    if rank['host']:
        command = ssh_command(rank['host'], shlex.join(command))
    path = Path(rank['local']) / 'stderr.log'
    with path.open('wb') as stderr:
        path.chmod(0o600)
        return subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=stderr, start_new_session=True, bufsize=0)
