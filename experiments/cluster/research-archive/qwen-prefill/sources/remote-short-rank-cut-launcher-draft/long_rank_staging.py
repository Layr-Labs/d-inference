"""Stage immutable rank files and exact raw prompt/teacher bytes for both owners."""
import json
from pathlib import Path
from prefill_compute_archive import digest, write_json
from long_reference_inputs import ARTIFACT, CONFIGURATION, require, read_pinned
from long_rank_configuration import configuration, require_configuration, hostfile, REQUIRED_ENVIRONMENT


def prepare_ranks(output, layout, host, bundle_hash, binary_hash, inputs, endpoints, epoch, scheduling=None):
    hostfile(endpoints)
    ranks, pinned = [], []
    prompt = read_pinned(output / 'inputs/prompt.json', inputs['prompt_file_sha256'], 65536)
    teacher = read_pinned(output / 'inputs/teacher.json', inputs['teacher_file_sha256'], 65536)
    hosts = json.dumps(endpoints).encode()
    for index, directory in enumerate(layout['rank_directories']):
        local = output / ('rank-' + str(index)); local.mkdir(mode=0o700)
        config = configuration(layout['bundle'], bundle_hash, layout['model'], inputs['prompt_file_sha256'], inputs['teacher_file_sha256'], index, epoch, scheduling)
        write_json(local / 'rank.json', config)
        for name, raw in [('prompt.json', prompt), ('teacher.json', teacher), ('hosts.json', hosts)]:
            with (local / name).open('xb') as stream: stream.write(raw)
            (local / name).chmod(0o400)
        ranks.append(dict(rank=index, host=host, directory=directory, local=str(local), bundle=layout['bundle']))
        pinned.append(dict(rank=index, directory=directory, rank_sha256=digest(local / 'rank.json'),
            prompt_sha256=digest(local / 'prompt.json'), prompt_size_bytes=len(prompt),
            teacher_sha256=digest(local / 'teacher.json'), teacher_size_bytes=len(teacher),
            hostfile_sha256=digest(local / 'hosts.json'), hostfile_size_bytes=len(hosts),
            required_environment=dict(REQUIRED_ENVIRONMENT, MLX_RANK=str(index))))
    controls = dict(layout, run_id=epoch, ranks=pinned, bundle_sha256=bundle_hash, hostfile=endpoints,
        binary_sha256=binary_hash, artifact_sha256=ARTIFACT, configuration_sha256=CONFIGURATION)
    return ranks, controls


def verify_remote(record, config, expected_files):
    require(record.get('artifact_aggregate_sha256') == ARTIFACT
        and record.get('bundle_manifest_sha256') == config['bundle_sha256']
        and record.get('bundle_file_sha256') == expected_files, 'Remote artifact/bundle identity differs')
    require(record['model_metadata']['config.json']['sha256'] == CONFIGURATION, 'Remote configuration pin differs')
    require([row['rank'] for row in record['ranks']] == [0, 1], 'Remote rank receipt order differs')
    for received, expected in zip(record['ranks'], config['ranks']):
        require(received['rank_configuration_sha256'] == expected['rank_sha256'], 'Remote rank configuration differs')
        require(received['raw_prompt_reencoded'] is False and received['raw_teacher_reencoded'] is False, 'Remote raw prompt/teacher was reencoded')
        for key in ('prompt_sha256','prompt_size_bytes','teacher_sha256','teacher_size_bytes','hostfile_sha256','hostfile_size_bytes'):
            require(type(received[key]) is type(expected[key]) and received[key] == expected[key], 'Remote staged input differs: ' + key)


def verify_local_rank_inputs(output, config, inputs, scheduling=None):
    for index, rank in enumerate(config['ranks']):
        directory = output / ('rank-' + str(index))
        path = directory / 'rank.json'
        require(path.stat().st_size <= 256 * 1024 and digest(path) == rank['rank_sha256'], 'Local rank configuration changed')
        require_configuration(json.loads(path.read_text()), config['bundle'], config['bundle_sha256'], config['model'],
            inputs['prompt_file_sha256'], inputs['teacher_file_sha256'], index, config['run_id'], scheduling)
        for name, key in [('prompt.json','prompt_sha256'), ('teacher.json','teacher_sha256'), ('hosts.json','hostfile_sha256')]:
            require(digest(directory / name) == rank[key], 'Local rank input changed')
        for name in ('prompt.json','teacher.json'):
            pin=inputs['prompt_file_sha256' if name=='prompt.json' else 'teacher_file_sha256']
            require(read_pinned(directory / name, pin, 65536) == read_pinned(output / 'inputs' / name, pin, 65536), 'Rank raw input bytes differ')
    for item in inputs['files']:
        path = output / item['path']
        require(path.stat().st_size == item['size_bytes'] and digest(path) == item['sha256'], 'Retained origin/input changed')
