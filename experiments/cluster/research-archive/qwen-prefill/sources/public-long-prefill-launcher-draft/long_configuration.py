"""Exact native configuration; raw prompt files are never worker-reencoded."""
import json
import re
from . import archive
from .common import integer, require, sha
from .long_profile import ARTIFACT, COMMANDS, NATIVE_TIMEOUT, POLICIES, REQUIRED_ENVIRONMENT
from .long_inputs import bounded_bytes


def endpoints(hosts):
    require(type(hosts) is list and len(hosts) == 2, 'Two loopback endpoints required')
    values = []
    for row in hosts:
        require(type(row) is list and len(row) == 1 and type(row[0]) is str, 'One endpoint per rank required')
        match = re.fullmatch(r'127\.0\.0\.1:([0-9]+)', row[0])
        require(match and str(int(match[1])) == match[1], 'Canonical literal loopback endpoint required')
        values.append(integer(int(match[1]), 1, 65535))
    require(values[0] != values[1], 'Loopback endpoints must differ')


def build(rank, context, bundle, bundle_hash, hosts):
    paired = context['mode'] == 'long-prefill-ranks'
    require(context['mode'] in COMMANDS, 'Unknown long command')
    integer(rank, 0, 1 if paired else 0); sha(bundle_hash)
    require(context['artifact'] == ARTIFACT and type(context['epoch']) is str
            and re.fullmatch('[0-9a-f]{32}', context['epoch']), 'Registered source/fresh epoch required')
    sha(context['prompt_file_sha256']); environment = dict(REQUIRED_ENVIRONMENT)
    arguments = ['--mode', 'qwen-long-prefill-rank-check' if paired else 'qwen-long-prefill-solo-check',
        '--model-dir', '@model', '--artifact-aggregate-sha256', ARTIFACT,
        '--execution-path', 'cbv2-contiguous', '--tokens-file', '@rank/prompt.json',
        '--long-prompt-sha256', context['prompt_file_sha256'], '--prompt-tokens', '8192',
        '--chunk-size', '512', '--decode-tokens', '1', '--repeats', '1', '--warmups', '0',
        '--seed', '7', '--timeout-seconds', str(NATIVE_TIMEOUT)]
    environment_files = {}
    if paired:
        endpoints(hosts)
        require(context['stage_prefill_policy'] in POLICIES and context['stage_logits_dtype'] == 'bfloat16',
                'Explicit long scheduling policy and BF16 logits required')
        environment['MLX_RANK'] = str(rank); environment_files['MLX_HOSTFILE'] = 'hosts.json'
        arguments += ['--transport', 'loopback-test', '--epoch', context['epoch'],
            '--stage-prefill-policy', context['stage_prefill_policy'], '--stage-logits-dtype', 'bfloat16']
    else:
        require(hosts is None and context['stage_prefill_policy'] is None and context['stage_logits_dtype'] is None,
                'Solo must not acquire stage or transport configuration')
    return dict(rank=rank, bundle=str(bundle), bundle_sha256=bundle_hash, persistent=False,
        model_directory=context['model'], artifact_aggregate_sha256=ARTIFACT,
        timeout_seconds=NATIVE_TIMEOUT, environment=environment, environment_files=environment_files,
        input_files={}, arguments=arguments)


def stage(output, context, bundle_hash, hosts):
    ranks, records = [], []
    prompt = bounded_bytes(output / 'inputs/prompt.json', 65536)
    require(archive.digest(output / 'inputs/prompt.json') == context['prompt_file_sha256'], 'Retained prompt changed')
    for rank in range(2 if context['mode'] == 'long-prefill-ranks' else 1):
        directory = output / ('rank-' + str(rank)); directory.mkdir(mode=0o700)
        config = build(rank, context, output / 'bundle', bundle_hash, hosts)
        archive.write_json(directory / 'rank.json', config)
        files = [('prompt.json', prompt)]
        if hosts is not None: files.append(('hosts.json', json.dumps(hosts).encode()))
        for name, raw in files:
            with (directory / name).open('xb') as stream: stream.write(raw)
            (directory / name).chmod(0o400)
        for path in sorted(directory.iterdir()):
            records.append(dict(path=path.relative_to(output).as_posix(), size_bytes=path.stat().st_size,
                                sha256=archive.digest(path)))
        ranks.append(dict(rank=rank, host=None, directory=str(directory), local=str(directory), bundle=str(output / 'bundle')))
    return ranks, records
