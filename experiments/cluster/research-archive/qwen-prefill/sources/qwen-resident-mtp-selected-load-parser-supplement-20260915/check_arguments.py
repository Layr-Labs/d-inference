#!/usr/bin/env python3
"""Run only the compiled fixture's pure parser mode, never its load command."""
import json
import subprocess
import sys


def arguments(binary):
    clock = subprocess.run([binary, 'clock'], capture_output=True, timeout=5, check=True)
    assert not clock.stderr and clock.stdout.strip().isdigit()
    now = int(clock.stdout)
    assert now > 0
    values = {
        '--model-dir': '/nonexistent-mtp-parser-only-model', '--rank': '1', '--stage-cut': '4',
        '--membership-epoch': '8e1b2d57-d0de-4c70-af6e-9c590d91acbc',
        '--model-id': 'registered_qwen35_9b', '--artifact-sha256': 'a' * 64,
        '--configuration-sha256': 'b' * 64, '--peer0-id': 'peer0', '--peer0-build-sha256': 'c' * 64,
        '--peer1-id': 'peer1', '--peer1-build-sha256': 'c' * 64,
        '--deadline-uptime-nanoseconds': str(now + 60_000_000_000),
    }
    return [item for pair in values.items() for item in pair]


def main(binary):
    cases = [('accepted', None, None, True)]
    cases += [(key, key, value, False) for key, value in (
        ('--rank', '0'), ('--stage-cut', '8'), ('--stage-cut', '04'),
        ('--model-id', 'registered_qwen35_27b'), ('--peer1-id', 'peer0'),
        ('--artifact-sha256', 'A' * 64), ('--deadline-uptime-nanoseconds', '1'))]
    cases += [('lookahead', '--prefill-schedule', 'one_chunk_lookahead_v1', False),
              ('unknown', '--mtp-enabled', 'true', False),
              ('partial-bootstrap', '--bootstrap-owner-pid', '99', False)]
    for label, key, value, accepted in cases:
        args = arguments(binary)
        if key in args:
            args[args.index(key) + 1] = value
        elif key is not None:
            args += [key, value]
        result = subprocess.run([binary, 'check-arguments'] + args, capture_output=True, timeout=5)
        if accepted:
            assert result.returncode == 0 and not result.stderr, label
            assert json.loads(result.stdout) == {'argumentsAccepted': True, 'modelLoaded': False}, label
        else:
            assert result.returncode != 0 and not result.stdout, label
    print('arguments: 11 groups passed; nonexistent model path and no load invocation')


if __name__ == '__main__':
    main(sys.argv[1])
