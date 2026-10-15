"""Pinned remote observations; executed only by the root-run launcher over SSH."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
from artifacts import file_sha256, verify_files, verify_model
from prefill_compute_memory import initial_free_screen, resource_preflight, sample_memory


def require(value, message):
    if not value:
        raise ValueError(message)


def process_inventory(config):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,rss=,command='],
                            check=True, capture_output=True, text=True, timeout=1)
    return parse_process_inventory(result.stdout, config)


def parse_process_inventory(raw, config):
    require(len(raw.encode()) <= 2 * 1024**2, 'Process inventory too large')
    binary = str(Path(config['bundle']) / 'cluster-inference')
    worker = str(Path(config['bundle']) / 'rank_worker.py')
    ranks = config['ranks']
    rows = []
    for line in raw.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) != 5:
            continue
        command = parts[4]
        kind = None
        index = None
        if command == binary or command.startswith(binary + ' '):
            kind = 'native'
            matched = [row['rank'] for row in ranks if str(Path(row['directory']) / 'prompt.json') in command.split()]
            require(len(matched) == 1, 'Cannot identify owned native rank from exact staged tokens path')
            index = matched[0]
        elif worker in command.split():
            matched = [row['rank'] for row in ranks if str(Path(row['directory']) / 'rank.json') in command.split()]
            require(len(matched) == 1, 'Cannot identify owned supervisor rank')
            kind = 'supervisor'
            index = matched[0]
        if kind:
            require(all(int(value) >= 0 for value in parts[:4]), 'Invalid owned process observation')
            rows.append(dict(kind=kind, rank=index, pid=int(parts[0]), ppid=int(parts[1]),
                             pgid=int(parts[2]), rssBytes=int(parts[3]) * 1024, command=command))
    require(len(rows) <= 16, 'Too many processes matching the owned run')
    return dict(observed_processes=rows, exact_run_path_match=True,
                observation_is_not_waitpid_or_remote_reaping_proof=True,
                rss_is_sampled_not_peak=True, missing_process_rss_is_not_assumed_zero=True)


def observation(config):
    result = sample_memory()
    result['remote_pid_inventory'] = process_inventory(config)
    return result


def verify_and_record(config, phase):
    root, bundle, model = (Path(config[key]) for key in ('run', 'bundle', 'model'))
    require(file_sha256(bundle / 'bundle.json') == config['bundle_sha256'], 'Bundle manifest changed')
    manifest = json.loads((bundle / 'bundle.json').read_text())
    bundle_files = verify_files(bundle, manifest['files'])
    require(bundle_files.get('cluster-inference') == config['binary_sha256'], 'Native binary changed')
    require([row['rank'] for row in config['ranks']] == [0, 1], 'Exactly two ordered rank configurations required')
    rank_records = []
    for rank in config['ranks']:
        native = Path(rank['directory'])
        require((native / 'rank.json').stat().st_size <= 256 * 1024, 'Rank configuration exceeds bound')
        require(file_sha256(native / 'rank.json') == rank['rank_sha256'], 'Remote rank configuration changed')
        saved_rank = json.loads((native / 'rank.json').read_text())
        require(saved_rank.get('input_files') == {}
            and saved_rank.get('environment_files') == {'MLX_HOSTFILE': 'hosts.json'}
            and saved_rank.get('environment') == rank['required_environment'],
            'Worker must preserve raw prompt/teacher/hostfile and exact arithmetic environment')
        item = dict(rank=rank['rank'], rank_configuration_sha256=file_sha256(native / 'rank.json'))
        for name, key, size_key, maximum in [('prompt.json','prompt_sha256','prompt_size_bytes',65536),
                                            ('teacher.json','teacher_sha256','teacher_size_bytes',65536),
                                            ('hosts.json','hostfile_sha256','hostfile_size_bytes',1024)]:
            path = native / name
            require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= maximum
                and path.stat().st_size == rank[size_key] and file_sha256(path) == rank[key], 'Remote raw rank input changed')
            if phase == 'before': path.chmod(0o400)
            item[key], item[size_key] = file_sha256(path), path.stat().st_size
        require(json.loads((native / 'hosts.json').read_text()) == config['hostfile'], 'Remote loopback hostfile changed')
        item['raw_prompt_reencoded'] = False
        item['raw_teacher_reencoded'] = False
        rank_records.append(item)
    require(file_sha256(model / 'config.json') == config['configuration_sha256'], 'Remote model configuration changed')
    aggregate = verify_model(model, config['artifact_sha256'])
    metadata = {}
    for name in ('config.json', 'manifest.json'):
        source = model / name
        require(source.stat().st_size <= 1024**2, 'Model metadata exceeds one MiB')
        destination = root / 'metadata' / (phase + '-' + name)
        require(not destination.exists(), 'Refusing to overwrite saved metadata')
        before = file_sha256(source)
        with destination.open('xb') as target, source.open('rb') as stream:
            shutil.copyfileobj(stream, target)
        destination.chmod(0o400)
        require(file_sha256(source) == before == file_sha256(destination), 'Metadata changed during copy')
        metadata[name] = dict(sha256=before, size_bytes=destination.stat().st_size,
                              remote_path=str(destination))
    result = dict(artifact_aggregate_sha256=aggregate, bundle_manifest_sha256=config['bundle_sha256'],
                  bundle_file_sha256=bundle_files, model_metadata=metadata,
                  ranks=rank_records)
    if phase == 'before':
        result['posthash_preflight'] = resource_preflight(root)
    result['memory'] = observation(config)
    return result


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    require(len(arguments) == 1 and arguments[0] in ('initial', 'before', 'observe', 'after'), 'Unknown control operation')
    operation = arguments[0]
    config = json.loads((Path(__file__).parent / 'control-config.json').read_text())
    if operation == 'initial':
        result = initial_free_screen()
        result['phase'] = 'remote_before_bundle_staging_and_remote_artifact_hashing'
    elif operation == 'observe':
        result = observation(config)
    else:
        result = verify_and_record(config, operation)
    print(json.dumps(dict(kind='long_rank_control', schema_version=1, operation=operation,
                         run_id=config['run_id'], remote_run=config['run'], result=result),
                     sort_keys=True, allow_nan=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
