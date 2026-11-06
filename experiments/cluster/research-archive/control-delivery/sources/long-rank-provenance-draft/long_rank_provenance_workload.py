"""Exact saved rank command/input/control identity; native streams stay opaque."""
import hashlib
import json
from long_reference_provenance_common import raw, read, require, safe_relative, sha, valid_hash
from long_rank_provenance_prompt import prompt_bytes
from long_rank_provenance_records import ARITHMETIC, expected_rank, validate_hostfile


def manifest_declaration(run, pins, tokenizer_sha):
    for name in ('config.json', 'manifest.json'):
        require(raw(run / 'remote-metadata' / ('before-' + name), 1024**2)
                == raw(run / 'remote-metadata' / ('after-' + name), 1024**2), 'Remote model metadata changed')
    require(sha(run / 'remote-metadata/before-config.json') == pins.configuration, 'Remote configuration pin differs')
    manifest = read(run / 'remote-metadata/before-manifest.json')
    listed = manifest['files']; require(type(listed) is list and 1 <= len(listed) <= 128, 'Unbounded model declaration')
    declared = {}
    for entry in listed:
        safe_relative(entry['path']); valid_hash(entry['sha256'])
        require(entry['path'] not in declared and type(entry['size_bytes']) is int
                and 0 <= entry['size_bytes'] <= 8 * 1024**3, 'Invalid duplicate model declaration')
        declared[entry['path']] = entry
    total = sum(entry['size_bytes'] for entry in declared.values())
    aggregate = hashlib.sha256(b''.join(bytes.fromhex(declared[name]['sha256']) for name in sorted(declared))).hexdigest()
    require(type(manifest['file_count']) is int and len(declared) == manifest['file_count']
            and type(manifest['total_size_bytes']) is int and total == manifest['total_size_bytes'] <= 8 * 1024**3
            and aggregate == manifest['aggregate_sha256'] == pins.artifact
            and declared['tokenizer.json']['sha256'] == tokenizer_sha, 'Artifact declaration aggregate differs')
    return total


def workload_and_controls(run, receipt, pins, bundle, origin_directory):
    inputs = prompt_bytes(run, receipt, pins, origin_directory)
    endpoints = validate_hostfile(receipt['hostfile'])
    hosts = json.dumps(endpoints).encode()
    host_sha = hashlib.sha256(hosts).hexdigest()
    remote = receipt['remote_paths']; epoch = receipt['epoch']
    require(receipt['remote_port_reservation'] == dict(run=remote['run'], hostfile=endpoints,
        reservationOpen=False, method='remote_AF_INET_loopback_two_simultaneous_bind_then_close',
        raceFailsWithoutFallback=True), 'Port reservation attestation differs')
    require(receipt['remote_port_reservation']['reservationOpen'] is False
            and receipt['remote_port_reservation']['raceFailsWithoutFallback'] is True, 'Port reservation scope differs')
    ranks, output = [], []
    for rank in range(2):
        directory = run / ('rank-' + str(rank))
        copied = run / 'remote-metadata' / ('rank-' + str(rank) + '-rank.json')
        require(read(directory / 'rank.json') == read(copied) == expected_rank(receipt, pins, rank)
                and sha(directory / 'rank.json') == sha(copied) == receipt['rank_configuration_sha256'][rank],
                'Exact rank configuration differs')
        require(raw(directory / 'prompt.json', 65536) == raw(run / 'inputs/prompt.json', 65536), 'Local raw rank prompt differs')
        require(raw(directory / 'hosts.json', 1024) == hosts
                == raw(run / 'remote-metadata' / ('rank-' + str(rank) + '-hosts.json'), 1024), 'Exact rank loopback bytes differ')
        ranks.append(dict(rank=rank, directory=remote['rank_directories'][rank],
            rank_sha256=sha(directory / 'rank.json'), prompt_sha256=pins.prompt,
            prompt_size_bytes=inputs['rawPromptBytes'], hostfile_sha256=host_sha, hostfile_size_bytes=len(hosts),
            required_environment=dict(ARITHMETIC, MLX_RANK=str(rank))))
        stdout = raw(directory / 'stdout.jsonl', 8 * 1024**2)
        require(stdout.endswith(b'\n') and len(stdout.splitlines()) == 2 and all(stdout.splitlines()),
                'Expected exactly two complete opaque records per rank')
        output.append(dict(rank=rank, stdoutSHA256=hashlib.sha256(stdout).hexdigest(), stdoutBytes=len(stdout),
                           nativeOutputFramingRecords=2, nativeOutputJSONParsed=False))
    config = dict(remote, run_id=epoch, ranks=ranks, bundle_sha256=receipt['bundle_manifest_sha256'],
        hostfile=endpoints, binary_sha256=pins.native, artifact_sha256=pins.artifact, configuration_sha256=pins.configuration)
    require(read(run / 'controls/control-config.json') == config, 'Controls do not bind both exact ranks and raw inputs')
    for phase in ('before', 'after'):
        record = receipt['remote_' + phase]
        require(record['artifact_aggregate_sha256'] == pins.artifact
                and record['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256']
                and record['bundle_file_sha256'] == bundle and len(record['ranks']) == 2,
                'Remote bundle/model verification attestation differs')
        for rank, item in enumerate(record['ranks']):
            expected = dict(rank=rank, rank_configuration_sha256=ranks[rank]['rank_sha256'],
                prompt_sha256=pins.prompt, prompt_size_bytes=inputs['rawPromptBytes'],
                hostfile_sha256=host_sha, hostfile_size_bytes=len(hosts), raw_prompt_reencoded=False)
            require(item == expected and item['raw_prompt_reencoded'] is False
                    and all(type(item[key]) is int for key in ('rank', 'prompt_size_bytes', 'hostfile_size_bytes')),
                    'Remote raw rank verification differs')
        for name in ('config.json', 'manifest.json'):
            item = record['model_metadata'][name]; local = run / 'remote-metadata' / (phase + '-' + name)
            require(item == dict(remote_path=remote['run'] + '/metadata/' + phase + '-' + name,
                sha256=sha(local), size_bytes=local.stat().st_size) and type(item['size_bytes']) is int
                and 0 < item['size_bytes'] <= 1024**2, 'Fetched model metadata attestation differs')
    total = manifest_declaration(run, pins, inputs['tokenizerJSONSHA256'])
    return dict(inputs, exactRankArgumentsVerified=True, exactRankLocalAndRemoteHostBytes=True,
        rawPromptCopiedToBothRanks=True, rankStreams=output, endpointPair=endpoints,
        endpointsHeldThroughLaunch=False, numericalResultIndependentlyVerified=False,
        declaredArtifactPayloadBytes=total, remoteFullArtifactBeforeAfterAttestationsMatch=True,
        modelPayloadIndependentlyRehashed=False)
