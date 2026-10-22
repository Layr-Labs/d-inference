"""Post-run pins and bounded output receipts; never deletes retained evidence."""
import json
from prefill_compute_archive import digest, verify_archive
from long_reference_configuration import require_rank_configuration
from long_reference_contract import MAX_STDOUT, MAX_STDERR
from long_reference_inputs import ARTIFACT, CONFIGURATION, require


def verified_remote(record, config, expected_files):
    require(record.get('artifact_aggregate_sha256') == ARTIFACT
            and record.get('bundle_manifest_sha256') == config['bundle_sha256']
            and record.get('bundle_file_sha256') == expected_files
            and record.get('rank_configuration_sha256') == config['rank_sha256'],
            'Remote artifact/bundle/rank identity differs')
    require(record['model_metadata']['config.json']['sha256'] == CONFIGURATION,
            'Remote configuration pin differs')
    require(record.get('prompt_sha256') == config['prompt_sha256']
            and type(record.get('prompt_size_bytes')) is int
            and record['prompt_size_bytes'] == config['prompt_size_bytes']
            and record.get('raw_prompt_reencoded') is False, 'Remote exact raw prompt differs')
    require(record.get('teacher_sha256') == config['teacher_sha256']
            and type(record.get('teacher_size_bytes')) is int
            and record['teacher_size_bytes'] == config['teacher_size_bytes']
            and record.get('raw_teacher_reencoded') is False, 'Remote exact raw teacher differs')


def verify_local(modules, output, sources, bundle_hash, launcher, inputs, config, controls_hash):
    verify_archive(modules, output, sources, bundle_hash, launcher)
    path = output / 'native/rank.json'
    require(path.stat().st_size <= 256 * 1024 and digest(path) == config['rank_sha256'],
            'Local rank configuration changed')
    require_rank_configuration(json.loads(path.read_text()), config['bundle'], bundle_hash,
                               config['model'], config['prompt_sha256'], config['teacher_sha256'])
    for entry in inputs['files']:
        path = output / entry['path']
        require(path.stat().st_size == entry['size_bytes'] and digest(path) == entry['sha256'],
                'Local retained input changed')
    manifest = output / 'controls/control-manifest.json'
    require(digest(manifest) == controls_hash, 'Local controls manifest changed')
    modules['artifacts'].verify_files(output / 'controls', json.loads(manifest.read_text())['files'])


def native_file_receipts(output):
    records = []
    for name, maximum in [('rank.json', 256 * 1024), ('stdout.jsonl', MAX_STDOUT), ('stderr.log', MAX_STDERR)]:
        path = output / 'native' / name
        if not path.is_file():
            continue
        size = path.stat().st_size
        records.append(dict(path='native/' + name, size_bytes=size,
                            sha256=digest(path) if size <= maximum else None,
                            hash_omitted_because_oversized=size > maximum, maximum_bytes=maximum))
    return records
