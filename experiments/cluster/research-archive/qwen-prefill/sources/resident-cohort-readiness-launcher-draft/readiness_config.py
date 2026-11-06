"""Closed local model-free cohort configuration; no model/input admission."""
import re
from pathlib import Path

SCENARIOS = ('match', 'warmup-mismatch', 'missing-peer')
NATIVE_SECONDS = 30
ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1',
               'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def require(value, message):
    if not value:
        raise ValueError(message)


def pin(value, length=64):
    require(type(value) is str and re.fullmatch('[0-9a-f]{' + str(length) + '}', value),
            'Expected a lowercase hexadecimal identity')
    return value


def parent_seconds(scenario):
    require(scenario in SCENARIOS, 'Unknown readiness scenario')
    return 3 if scenario == 'missing-peer' else 45


def configuration(bundle, bundle_sha, rank, epoch, scenario, hosts):
    pin(bundle_sha); pin(epoch, 32); parent_seconds(scenario)
    require(type(rank) is int and rank in (0, 1), 'Only ranks zero and one are admitted')
    require(type(hosts) is list and len(hosts) == 2, 'Two loopback endpoints required')
    ports = []
    for row in hosts:
        require(type(row) is list and len(row) == 1 and type(row[0]) is str, 'Invalid host row')
        match = re.fullmatch(r'127\.0\.0\.1:([1-9][0-9]{0,4})', row[0])
        require(match is not None and int(match[1]) <= 65535, 'Only IPv4 loopback is admitted')
        ports.append(int(match[1]))
    require(len(set(ports)) == 2, 'Loopback ports must be distinct')
    case = 'warmup-mismatch' if scenario == 'warmup-mismatch' else 'match'
    return dict(bundle=str(Path(bundle)), bundle_sha256=bundle_sha, rank=rank,
        arguments=['--mode', 'qwen-long-prefill-cohort-readiness-check', '--transport',
                   'loopback-test', '--epoch', epoch, '--cohort-readiness-case', case,
                   '--timeout-seconds', str(NATIVE_SECONDS)],
        environment=dict(ENVIRONMENT, MLX_RANK=str(rank)),
        environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={},
        timeout_seconds=NATIVE_SECONDS, persistent=False)
