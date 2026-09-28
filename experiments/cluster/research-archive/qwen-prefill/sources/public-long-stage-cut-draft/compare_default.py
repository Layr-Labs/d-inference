"""Compare default public context/configuration bytes with retained source files."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def original(name):
    path = HERE / 'originals/experiments/cluster/runtime/stage_checks' / (name + '.py')
    spec = importlib.util.spec_from_file_location('runtime.stage_checks._retained_' + name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def run(repository):
    sys.path[:0] = [str(HERE / 'proposed/experiments/cluster'), str(repository / 'experiments/cluster')]
    import runtime.stage_checks
    runtime.stage_checks.__path__.insert(0, str(HERE / 'proposed/experiments/cluster/runtime/stage_checks'))
    from runtime.stage_checks import long_inputs, long_configuration
    from runtime.stage_checks.common import canonical, digest
    from runtime.stage_checks.long_profile import ARTIFACT
    from stage_long_test_support import context, EPOCH
    old_inputs, old_configuration = original('long_inputs'), original('long_configuration')
    rows = []; hosts = [['127.0.0.1:31001'], ['127.0.0.1:31002']]
    for mode in ('long-prefill-ranks', 'long-prefill-solo'):
        for policy in (('serial_v1', 'prompt_lookahead_one_v1') if mode.endswith('ranks') else (None,)):
            for traced in (None, False, True):
                ctx = context(mode); ctx['stage_prefill_policy'] = policy
                if traced is not None: ctx['prefill_phase_trace'] = traced
                for rank in range(2 if mode.endswith('ranks') else 1):
                    args = (rank, ctx, '/synthetic-bundle', 'c' * 64, hosts if mode.endswith('ranks') else None)
                    before = canonical(old_configuration.build(*args)); after = canonical(long_configuration.build(*args))
                    assert before == after
                    rows.append(dict(kind='configuration', mode=mode, policy=policy, rank=rank, phase=traced,
                                     sha256=digest(after), size_bytes=len(after)))
    with tempfile.TemporaryDirectory(prefix='long-cut-default-cpu-') as directory:
        base = Path(directory); model = base / 'model'; model.mkdir()
        config = b'{"synthetic":true}\n'; (model / 'config.json').write_bytes(config)
        (model / 'manifest.json').write_bytes(canonical(dict(aggregate_sha256=ARTIFACT, total_size_bytes=len(config),
            files=[dict(path='config.json', sha256=digest(config))])))
        prompt = base / 'prompt.json'; prompt.write_bytes(b' \n' + canonical([3] * 8192) + b'\n')
        origin = base / 'origin.json'; origin.write_bytes(b'opaque synthetic origin\n')
        artifacts = SimpleNamespace(verify_model=lambda *_: None)
        for mode in ('long-prefill-ranks', 'long-prefill-solo'):
            for traced in (None, False, True):
                args = SimpleNamespace(command=mode, artifact_aggregate_sha256=ARTIFACT, model_dir=model,
                    tokens_file=prompt, tokens_sha256=digest(prompt.read_bytes()), prompt_origin_file=origin,
                    prompt_origin_sha256=digest(origin.read_bytes()), stage_prefill_policy='serial_v1' if mode.endswith('ranks') else None,
                    stage_logits_dtype='bfloat16' if mode.endswith('ranks') else None)
                if traced is not None: args.prefill_phase_trace = traced
                left = base / (mode + '-' + str(traced) + '-old'); right = base / (mode + '-' + str(traced) + '-new')
                left.mkdir(); right.mkdir()
                with patch.object(old_inputs, 'CONFIGURATION', digest(config)), patch.object(long_inputs, 'CONFIGURATION', digest(config)):
                    before = old_inputs.prepare(args, left, EPOCH, artifacts)
                    after = long_inputs.prepare(args, right, EPOCH, artifacts)
                assert canonical(before) == canonical(after) and 'stage_cut' not in after
                for item in after['files']: assert (left / item['path']).read_bytes() == (right / item['path']).read_bytes()
                rows.append(dict(kind='context_and_retained_bytes', mode=mode, phase=traced, passed=True))
    return dict(kind='public_long_cut_saved_default_comparison', passed=True, comparisons=len(rows), cases=rows,
        model_payload_read=False, native_executed=False, real_process_or_socket_used=False,
        scope='Default context/retained bytes and native configuration serialization only; no executable qualification.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--repository', type=Path, required=True)
    args = parser.parse_args()
    with patch('subprocess.Popen', side_effect=AssertionError('No process')), patch('subprocess.run', side_effect=AssertionError('No process')), \
         patch('socket.socket', side_effect=AssertionError('No socket')):
        print(json.dumps(run(args.repository.resolve()), indent=2, sort_keys=True))
