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
    rank_file = str(Path(config['native']) / 'rank.json')
    rows = []
    for line in raw.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) != 5:
            continue
        command = parts[4]
        kind = None
        if command == binary or command.startswith(binary + ' '):
            kind = 'native'
        elif worker in command.split() and rank_file in command.split():
            kind = 'supervisor'
        if kind:
            require(all(int(value) >= 0 for value in parts[:4]), 'Invalid owned process observation')
            rows.append(dict(kind=kind, pid=int(parts[0]), ppid=int(parts[1]),
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
    root, native, bundle, model = (Path(config[key]) for key in ('run', 'native', 'bundle', 'model'))
    require(file_sha256(bundle / 'bundle.json') == config['bundle_sha256'], 'Bundle manifest changed')
    manifest = json.loads((bundle / 'bundle.json').read_text())
    bundle_files = verify_files(bundle, manifest['files'])
    require(bundle_files.get('cluster-inference') == config['binary_sha256'], 'Native binary changed')
    require((native / 'rank.json').stat().st_size <= 256 * 1024, 'Rank configuration exceeds bound')
    require(file_sha256(native / 'rank.json') == config['rank_sha256'], 'Remote rank configuration changed')
    saved_rank = json.loads((native / 'rank.json').read_text())
    require(saved_rank.get('input_files') == {} and saved_rank.get('environment_files') == {}
            and saved_rank.get('environment') == config['required_environment'],
            'Worker must preserve staged raw input and exact arithmetic environment')
    prompt = native / 'prompt.json'
    require(prompt.is_file() and not prompt.is_symlink()
            and 0 < prompt.stat().st_size <= 65536
            and prompt.stat().st_size == config['prompt_size_bytes']
            and file_sha256(prompt) == config['prompt_sha256'], 'Remote raw prompt changed')
    # The input is copied by SCP, never JSON-reencoded by this control or the
    # unchanged worker. Seal the owned copy before native execution.
    if phase == 'before':
        prompt.chmod(0o400)
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
                  rank_configuration_sha256=file_sha256(native / 'rank.json'),
                  prompt_sha256=file_sha256(prompt), prompt_size_bytes=prompt.stat().st_size,
                  raw_prompt_reencoded=False)
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
    print(json.dumps(dict(kind='remote_prefill_control', schema_version=1, operation=operation,
                         run_id=config['run_id'], remote_run=config['run'], result=result),
                     sort_keys=True, allow_nan=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
