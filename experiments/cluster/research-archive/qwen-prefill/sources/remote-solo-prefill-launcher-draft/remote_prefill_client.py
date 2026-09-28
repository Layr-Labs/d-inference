"""Stage exclusively owned paths and execute hash-pinned remote observations."""
from decimal import Decimal
import json
from pathlib import Path
import shlex
import shutil
from prefill_compute_archive import digest, write_json
from prefill_compute_contract import parse, require
from remote_prefill_paths import ABSENT, BOOTSTRAP, PINNED_RUNNER, host_alias, paths


def create_remote(processes, host, model, requested_root, run_id):
    host_alias(host)
    home = processes.ssh(host, ['/usr/bin/python3', '-c', 'from pathlib import Path; print(Path.home())'],
                         capture_output=True, text=True, timeout=10).stdout.strip()
    layout = paths(home, requested_root, model, run_id)
    result = processes.ssh(host, ['/usr/bin/python3', '-c', BOOTSTRAP, layout['root'], run_id],
                           capture_output=True, text=True, timeout=10)
    require(result.stdout.strip() == layout['run'], 'Remote exclusive directory differs')
    return layout


def upload_new(processes, host, source, destination):
    processes.ssh(host, ['/usr/bin/python3', '-c', ABSENT, destination], timeout=10)
    processes.scp(str(source), host + ':' + shlex.quote(str(destination)))


def prepare_controls(output, layout, config):
    folder = output / 'controls'
    folder.mkdir(mode=0o700)
    here = Path(__file__).parent
    for source in (here / 'remote_prefill_control.py', here / 'prefill_compute_memory.py', output / 'bundle/artifacts.py'):
        shutil.copyfile(source, folder / source.name)
    write_json(folder / 'control-config.json', config)
    files = [dict(path=p.name, sha256=digest(p), size_bytes=p.stat().st_size) for p in sorted(folder.iterdir())]
    write_json(folder / 'control-manifest.json', dict(schema_version=1, files=files))
    for path in folder.iterdir():
        path.chmod(0o400)
    return digest(folder / 'control-manifest.json')


class RemoteControl:
    def __init__(self, processes, host, layout, run_id, manifest_hash, output):
        self.processes, self.host, self.layout = processes, host, layout
        self.run_id, self.manifest_hash = run_id, manifest_hash
        self.records = output / 'remote-observations'
        self.records.mkdir(mode=0o700)
        self.calls = []

    def call(self, operation, timeout=120):
        require(operation in ('initial', 'before', 'observe', 'after'), 'Unknown remote operation')
        command = ['/usr/bin/python3', '-c', PINNED_RUNNER,
                   self.layout['controls'] + '/control-manifest.json', self.manifest_hash, operation]
        entry = dict(operation=operation, timeout_seconds=timeout)
        self.calls.append(entry)
        path = self.records / ('%04d-%s.json' % (len(self.calls), operation))
        try:
            result = self.processes.ssh(self.host, command, capture_output=True, text=True, timeout=timeout)
            require(len(result.stdout.encode()) <= 2 * 1024**2 and len(result.stderr.encode()) <= 65536,
                    'Remote control output exceeds bound')
            require(not result.stderr, 'Remote control emitted stderr')
            record = parse(result.stdout)
            require(isinstance(record, dict) and record.get('kind') == 'remote_prefill_control'
                    and type(record.get('schema_version')) is int and record['schema_version'] == 1
                    and record.get('operation') == operation and record.get('run_id') == self.run_id
                    and record.get('remote_run') == self.layout['run'] and isinstance(record.get('result'), dict),
                    'Remote control identity differs')
            entry.update(passed=True, record=record)
            return record['result']
        except BaseException as error:
            entry.update(passed=False, error=type(error).__name__ + ': ' + str(error))
            for key in ('stdout', 'stderr'):
                value = getattr(error, key, None)
                if value is not None:
                    entry[key] = (value.decode(errors='replace') if isinstance(value, bytes) else str(value))[:65536]
            raise
        finally:
            write_json(path, entry)


class RemoteMemoryGate:
    def __init__(self):
        self.samples, self.initial_swap = [], None

    def consume(self, value):
        self.samples.append(value)
        require(type(value.get('pressure_level')) is int and 0 <= value['pressure_level'] <= 2,
                'Remote memory pressure exceeds level 2')
        used = Decimal(value['swap_used_bytes'])
        require(used.is_finite() and used >= 0, 'Invalid remote reported swap')
        if self.initial_swap is None:
            self.initial_swap = used
        require(used <= self.initial_swap, 'New remote OS-reported swap usage')
        require(isinstance(value.get('remote_pid_inventory'), dict), 'Missing remote PID observations')
        return value


def collect_metadata(processes, host, layout, before, after, output):
    destination = output / 'remote-metadata'
    destination.mkdir(mode=0o700)
    entries = []
    requested = []
    for phase, record in (('before', before), ('after', after)):
        for name in ('config.json', 'manifest.json'):
            item = record['model_metadata'][name]
            expected_remote = layout['run'] + '/metadata/' + phase + '-' + name
            require(item['remote_path'] == expected_remote, 'Unexpected remote metadata path')
            requested.append((expected_remote, phase + '-' + name, item['sha256']))
    requested += [(layout['native'] + '/rank.json', 'rank.final.json', after['rank_configuration_sha256']),
                  (layout['native'] + '/prompt.json', 'prompt.final.json', after['prompt_sha256']),
                  (layout['native'] + '/solo-reference.json', 'solo-reference.final.json', after['solo_reference_sha256'])]
    for remote, name, expected in requested:
        target = destination / name
        require(not target.exists(), 'Refusing metadata overwrite')
        processes.scp(host + ':' + shlex.quote(remote), str(target))
        require(target.is_file() and target.stat().st_size <= 1024**2 and digest(target) == expected,
                'Retrieved metadata differs')
        target.chmod(0o400)
        entries.append(dict(path=target.relative_to(output).as_posix(), sha256=expected,
                            size_bytes=target.stat().st_size))
    return entries
