"""Native CLI/pipe refusal checks using metadata only; no model weights exist."""

import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

root = Path(__file__).resolve().parent
out = root / 'entry-check'
out.mkdir(mode=0o700)
model = out / 'metadata-only'
model.mkdir(mode=0o700)
retained = root.parents[1] / 'd-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json'
configuration = base64.b64decode(json.loads(retained.read_bytes())['nine']['configuration'])
assert hashlib.sha256(configuration).hexdigest() == 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
(model / 'config.json').write_bytes(configuration)
tokens = json.dumps([0] * 8192, separators=(',', ':')).encode()
token_file = out / 'tokens.json'
token_file.write_bytes(tokens)
build = json.loads((root / 'records/build-3.json').read_bytes())
binary = root / 'workspace/experiments/cluster/inference/.build/arm64-apple-macosx/release/cluster-inference'
assert build['exit_code'] == 0 and hashlib.sha256(binary.read_bytes()).hexdigest() == build['binary_sha256']
command = [str(binary), '--mode', 'qwen-resident-benchmark-worker', '--role', 'solo',
           '--model-dir', str(model), '--artifact-aggregate-sha256',
           '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
           '--tokens-file', str(token_file), '--long-prompt-sha256', hashlib.sha256(tokens).hexdigest(),
           '--timeout-seconds', '1']
env = os.environ.copy()
env.update(DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128', DARKBLOOM_BF16_WEIGHTS='1', MLX_ENABLE_TF32='1')
env.pop('MLX_METAL_GPU_ARCH', None)
env.pop('MLX_SDPA_BLOCKS', None)
schema = 'qwen_resident_benchmark_worker_v1'
opened = dict(schema=schema, type='open', cohort_id='entry:solo', requests=[
    dict(request_id='entry:solo' + suffix, epoch='%032x' % (index + 1))
    for index, suffix in enumerate((':warmup:0', ':measured:0', ':measured:1', ':measured:2'))])
cases = [('eof-before-open', b'', 'opening command'),
         ('truncated-open', b'{"schema":"', 'inside a JSONL frame'),
         ('wrong-command', b'{"schema":"other"}\n', 'requires its schema'),
         ('actual-resource-refusal', json.dumps(opened).encode() + b'\n', None)]
records = []
for name, raw, expected in cases:
    start = time.monotonic()
    result = subprocess.run(command, input=raw, env=env, capture_output=True, timeout=5)
    (out / (name + '.stdin')).write_bytes(raw)
    (out / (name + '.stdout')).write_bytes(result.stdout)
    (out / (name + '.stderr')).write_bytes(result.stderr)
    error = result.stderr.decode()
    assert result.returncode == 1 and not result.stdout, (name, result.returncode, error)
    if expected is not None:
        assert expected in error, error
    else:
        # Valid metadata reaches the real OS/AC gate; no fabricated resource
        # observation is accepted. This run must stop before MLX/model loading.
        assert any(message in error for message in ('requires AC', 'at least 6 GiB actual free',
                   'Invalid, stale, pressured or swapped')), error
    records.append(dict(case=name, returncode=result.returncode, elapsed_seconds=time.monotonic() - start,
                        stdout_bytes=len(result.stdout), stderr_sha256=hashlib.sha256(result.stderr).hexdigest(),
                        observed_error=error.strip()))
start = time.monotonic()
process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env, start_new_session=True)
try:
    code = process.wait(timeout=5)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise
finally:
    process.stdin.close()
stdout = process.stdout.read()
stderr = process.stderr.read()
process.stdout.close()
process.stderr.close()
assert code == -signal.SIGALRM and not stdout and not stderr, (code, stdout, stderr)
records.append(dict(case='open-idle-fixed-deadline', returncode=code,
                    elapsed_seconds=time.monotonic() - start, stdout_bytes=0, stderr_bytes=0))
record = dict(schema='resident_worker_entry_refusal_check_v1', command=command,
              binary_sha256=build['binary_sha256'], source_snapshot_sha256=
              hashlib.sha256((root / 'records/source-snapshot.json').read_bytes()).hexdigest(),
              metadata_only=True, native_model_executed=False, model_weight_files_present=False,
              independent_native_allocation_observation=False, cases=records)
(out / 'execution.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record))
