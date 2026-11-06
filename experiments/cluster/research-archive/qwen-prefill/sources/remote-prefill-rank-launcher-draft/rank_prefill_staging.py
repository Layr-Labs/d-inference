"""Create exact two-rank files and bind pre/post remote verification receipts."""
import hashlib
import json
from pathlib import Path
from prefill_compute_archive import digest, write_json
from prefill_compute_inputs import ARTIFACT, CONFIGURATION
from rank_prefill_contract import configuration, require


def prepare_ranks(output, layout, host, bundle_hash, binary_hash, prompt, endpoints, epoch, scheduling, seconds):
    ranks, pinned = [], []
    prompt_hash = hashlib.sha256(json.dumps(prompt).encode()).hexdigest()
    hostfile_hash = hashlib.sha256(json.dumps(endpoints).encode()).hexdigest()
    for index, directory in enumerate(layout['rank_directories']):
        local = output / ('rank-' + str(index)); local.mkdir(mode=0o700)
        config = configuration(Path(layout['bundle']), bundle_hash, Path(layout['model']), prompt,
                               seconds, index, epoch, scheduling, endpoints)
        write_json(local / 'rank.json', config)
        ranks.append(dict(rank=index, host=host, directory=directory, local=str(local), bundle=layout['bundle']))
        pinned.append(dict(rank=index, directory=directory, rank_sha256=digest(local / 'rank.json'),
                           prompt_sha256=prompt_hash, hostfile_sha256=hostfile_hash))
    controls = dict(layout, run_id=epoch, ranks=pinned, bundle_sha256=bundle_hash,
                    binary_sha256=binary_hash, artifact_sha256=ARTIFACT, configuration_sha256=CONFIGURATION)
    return ranks, controls


def verify_remote(record, config, expected_files, phase):
    require(record.get('artifact_aggregate_sha256') == ARTIFACT
            and record.get('bundle_manifest_sha256') == config['bundle_sha256']
            and record.get('bundle_file_sha256') == expected_files, 'Remote artifact/bundle identity differs')
    require(record['model_metadata']['config.json']['sha256'] == CONFIGURATION, 'Remote configuration pin differs')
    require([row['rank'] for row in record['ranks']] == [0, 1], 'Remote rank receipt order differs')
    for received, expected in zip(record['ranks'], config['ranks']):
        require(received['rank_configuration_sha256'] == expected['rank_sha256'], 'Remote rank configuration differs')
        if phase == 'after':
            require(received['prompt_sha256'] == expected['prompt_sha256']
                    and received['hostfile_sha256'] == expected['hostfile_sha256'], 'Remote prompt/hostfile bytes differ')


def verify_local_rank_inputs(output, config, inputs):
    for index, rank in enumerate(config['ranks']):
        require(digest(output / ('rank-' + str(index)) / 'rank.json') == rank['rank_sha256'], 'Local rank configuration changed')
    for entry in inputs['files']:
        require(digest(output / entry['path']) == entry['sha256'], 'Retained input changed')
