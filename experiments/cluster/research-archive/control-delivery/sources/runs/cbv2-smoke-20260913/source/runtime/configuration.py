"""Validate a declarative run and generate identical workloads for its ranks."""

import ipaddress
import re
import socket

from .model_profiles import CBV2_SYNTHETIC_PROFILES, GEMMA_PROFILES, SYNTHETIC_PROFILES


def validate(spec):
    if not isinstance(spec, dict):
        raise ValueError('Run specification must be an object')
    allowed = {'schema_version', 'backend', 'ranks', 'workload', 'coordinator', 'devices',
               'artifact_aggregate_sha256', 'timeout_seconds', 'capture_logits', 'partition'}
    if set(spec) - allowed:
        raise ValueError(f'Unknown run fields: {sorted(set(spec) - allowed)}')
    if type(spec.get('schema_version')) is not int or spec['schema_version'] != 1:
        raise ValueError('Expected schema_version 1')
    backend = spec.get('backend')
    if backend not in ('solo', 'replicas', 'jaccl', 'loopback-test'):
        raise ValueError('Backend must be solo, replicas, jaccl or loopback-test')
    partition = spec.setdefault('partition', 'ffn')
    if partition not in ('ffn', 'full'):
        raise ValueError('Partition must be ffn or full')
    if partition == 'full' and backend not in ('jaccl', 'loopback-test'):
        raise ValueError('Full partitioning requires a cooperative backend')
    ranks = spec.get('ranks', [])
    if not isinstance(ranks, list) or not ranks or len(ranks) > 8:
        raise ValueError('Provide between 1 and 8 rank locations')
    if backend == 'solo' and len(ranks) != 1:
        raise ValueError('Solo runs require one rank')
    if backend in ('jaccl', 'loopback-test') and len(ranks) != 2:
        raise ValueError('This inference adapter requires exactly two cooperative ranks')
    if backend == 'replicas' and len(ranks) < 2:
        raise ValueError('Replica comparison requires at least two ranks')
    for rank in ranks:
        if not isinstance(rank, dict) or set(rank) - {'location', 'host', 'model_directory'}:
            raise ValueError('Rank must contain only location, host and model_directory')
        if rank.get('location') not in ('local', 'ssh'):
            raise ValueError('Rank location must be local or ssh')
        if rank['location'] == 'ssh':
            host = rank.get('host', '')
            if not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', host):
                raise ValueError('SSH hosts must be configured aliases')
    workload = spec.setdefault('workload', {})
    if not isinstance(workload, dict) or set(workload) - {
        'synthetic', 'prompt_tokens', 'chunk_size', 'decode_tokens', 'repeats',
        'warmups', 'seed', 'teacher_tokens', 'prompt_ids', 'synthetic_dtype', 'synthetic_profile',
        'attention_output_precision', 'ffn_branch_precision', 'execution_path'
    }:
        raise ValueError('Invalid or unknown workload fields')
    if not isinstance(workload.get('synthetic', False), bool):
        raise ValueError('workload.synthetic must be boolean')
    if workload.setdefault('execution_path', 'ordinary') not in ('ordinary', 'cbv2-contiguous'):
        raise ValueError('Execution path must be ordinary or cbv2-contiguous')
    if workload.setdefault('attention_output_precision', 'native') not in ('native', 'float32'):
        raise ValueError('Attention output precision must be native or float32')
    if workload.setdefault('ffn_branch_precision', 'native') not in (
        'native', 'float32', 'float32-through-norm'
    ):
        raise ValueError('FFN branch precision must be native, float32 or float32-through-norm')
    if workload.get('synthetic'):
        if workload.setdefault('synthetic_dtype', 'float32') not in ('float32', 'bfloat16'):
            raise ValueError('Synthetic dtype must be float32 or bfloat16')
        if workload.setdefault('synthetic_profile', 'tiny') not in SYNTHETIC_PROFILES:
            raise ValueError('Unsupported synthetic profile')
        if (workload['execution_path'] == 'cbv2-contiguous'
                and workload['synthetic_profile'] not in CBV2_SYNTHETIC_PROFILES):
            raise ValueError('CBv2 contiguous execution currently requires a dense Qwen synthetic profile')
        if workload['synthetic_profile'] in GEMMA_PROFILES and partition == 'full':
            raise ValueError('Gemma supports FFN partitioning only')
        if workload['synthetic_profile'] in GEMMA_PROFILES and workload['attention_output_precision'] != 'native':
            raise ValueError('Gemma supports native attention output precision only')
        if workload['synthetic_profile'] not in GEMMA_PROFILES and workload['ffn_branch_precision'] != 'native':
            raise ValueError('Float32 FFN branch precision requires a Gemma model')
    elif 'synthetic_dtype' in workload or 'synthetic_profile' in workload:
        raise ValueError('synthetic_dtype and synthetic_profile are only supported for synthetic weights')
    if workload['execution_path'] == 'cbv2-contiguous' and workload['ffn_branch_precision'] != 'native':
        raise ValueError('CBv2 contiguous execution requires native FFN branch precision')
    if backend == 'loopback-test' and (
        not workload.get('synthetic') or any(r['location'] != 'local' for r in ranks)
    ):
        raise ValueError('Loopback tests require synthetic weights and local processes')
    if backend == 'jaccl':
        if any(r['location'] != 'ssh' for r in ranks):
            raise ValueError('JACCL runs require two remote SSH nodes')
        if len({r['host'] for r in ranks}) != 2:
            raise ValueError('JACCL rank aliases must differ')
        if not isinstance(spec.get('coordinator'), str):
            raise ValueError('JACCL requires a coordinator IPv4 address:port')
        address, port = spec['coordinator'].rsplit(':', 1)
        ipaddress.IPv4Address(address)
        if not 1 <= int(port) <= 65535:
            raise ValueError('Invalid coordinator port')
        if not isinstance(spec.get('devices'), list) or len(spec['devices']) != 2 or any(
            not isinstance(d, str) or not re.fullmatch(r'rdma_en[0-9]+', d) for d in spec['devices']
        ):
            raise ValueError('Provide each node\'s connected RDMA device')
    if not workload.get('synthetic'):
        expected = spec.get('artifact_aggregate_sha256', '')
        if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('Real models require their expected registered aggregate SHA-256')
        if any(not isinstance(r.get('model_directory'), str) or not r['model_directory'].strip()
               for r in ranks):
            raise ValueError('Every real-model rank requires its model directory')
    prompt = workload.get('prompt_ids')
    if 'prompt_ids' in workload:
        if (not isinstance(prompt, list) or not prompt
                or any(type(token) is not int or token < 0 for token in prompt)):
            raise ValueError('Prompt IDs must be a nonempty list of nonnegative integers')
        if 'prompt_tokens' not in workload:
            workload['prompt_tokens'] = len(prompt)
    defaults = dict(prompt_tokens=65, chunk_size=32, decode_tokens=8,
                    repeats=1, warmups=0, seed=7)
    for name, default in defaults.items():
        value = workload.setdefault(name, default)
        minimum = 0 if name in ('warmups', 'seed') else 1
        if type(value) is not int or not minimum <= value <= 1_000_000:
            raise ValueError(f'Invalid workload count: {name}')
    if workload['execution_path'] == 'cbv2-contiguous' and (
        workload['prompt_tokens'] + workload['decode_tokens'] > 32768
        or workload['decode_tokens'] > 4096
    ):
        raise ValueError('CBv2 contiguous execution requires prompt plus output <= 32768 and output <= 4096')
    if prompt is not None and len(prompt) != workload['prompt_tokens']:
        raise ValueError('prompt_tokens must equal the number of supplied prompt IDs')
    teacher = workload.get('teacher_tokens')
    if teacher is not None and (
        not isinstance(teacher, list) or len(teacher) != workload['decode_tokens'] - 1
        or any(type(t) is not int or t < 0 for t in teacher)
    ):
        raise ValueError('Teacher tokens must contain decode_tokens minus one nonnegative IDs')
    timeout = spec.setdefault('timeout_seconds', 90)
    if type(timeout) is not int or not 1 <= timeout <= 600:
        raise ValueError('timeout_seconds must be between 1 and 600')
    if type(spec.setdefault('capture_logits', False)) is not bool:
        raise ValueError('capture_logits must be boolean')
    return spec


def loopback_addresses():
    # Bind both while allocating so they cannot accidentally receive one port.
    sockets = [socket.socket(), socket.socket()]
    try:
        for item in sockets:
            item.bind(('127.0.0.1', 0))
        return [[f'127.0.0.1:{item.getsockname()[1]}'] for item in sockets]
    finally:
        for item in sockets:
            item.close()


def rank_configuration(spec, rank, bundle, bundle_hash, hostfile):
    workload, backend = spec['workload'], spec['backend']
    cooperative = backend in ('jaccl', 'loopback-test')
    arguments = ['--mode', 'ffn-tp' if cooperative else 'baseline']
    arguments += ['--synthetic'] if workload.get('synthetic') else ['--model-dir', '@model']
    arguments += ['--attention-output-precision', workload['attention_output_precision']]
    arguments += ['--ffn-branch-precision', workload['ffn_branch_precision']]
    arguments += ['--execution-path', workload['execution_path']]
    if workload.get('synthetic'):
        arguments += ['--synthetic-dtype', workload['synthetic_dtype']]
        arguments += ['--synthetic-profile', workload['synthetic_profile']]
    if cooperative:
        arguments += ['--transport', backend, '--partition', spec['partition']]
    for name in ('prompt_tokens', 'chunk_size', 'decode_tokens', 'repeats', 'warmups', 'seed'):
        arguments += ['--' + name.replace('_', '-'), str(workload[name])]
    arguments += ['--timeout-seconds', str(spec['timeout_seconds'])]
    inputs, env_files = {}, {}
    environment = {'DARKBLOOM_BF16_WEIGHTS': '1'}
    if 'prompt_ids' in workload:
        inputs['prompt.json'] = workload['prompt_ids']
        arguments += ['--tokens-file', '@rank/prompt.json']
    if workload.get('teacher_tokens') is not None:
        inputs['teacher.json'] = workload['teacher_tokens']
        arguments += ['--teacher-tokens-file', '@rank/teacher.json']
    if spec['capture_logits']:
        arguments += ['--logits-file', '@rank/logits.json']
    if cooperative:
        environment['MLX_RANK'] = str(rank)
    if backend == 'loopback-test':
        inputs['hosts.json'] = hostfile
        env_files['MLX_HOSTFILE'] = 'hosts.json'
    elif backend == 'jaccl':
        inputs['devices.json'] = [[None, spec['devices'][0]], [spec['devices'][1], None]]
        env_files['MLX_IBV_DEVICES'] = 'devices.json'
        environment['MLX_JACCL_COORDINATOR'] = spec['coordinator']
    return dict(bundle=str(bundle), bundle_sha256=bundle_hash, rank=rank,
                arguments=arguments, environment=environment, environment_files=env_files,
                input_files=inputs, timeout_seconds=spec['timeout_seconds'],
                model_directory=spec['ranks'][rank].get('model_directory'),
                artifact_aggregate_sha256=spec.get('artifact_aggregate_sha256'))
