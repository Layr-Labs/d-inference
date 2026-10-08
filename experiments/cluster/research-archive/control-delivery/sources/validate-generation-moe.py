"""Bounded local synthetic validation; no hardware-throughput qualification."""
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER = REPO / 'experiments/cluster'
BUNDLE = CLUSTER / 'inference/.build/arm64-apple-macosx/release'
OUT = Path(sys.argv[1])
OUT.mkdir(mode=0o700)
receipt = dict(schema_version=1, real_model_tested=False, rdma_tested=False,
               target_m3_ultra_tested=False,
               binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
               native_checks=[], executions=[], parity=[])

def save():
    (OUT/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')

def command(name, arguments, timeout=90):
    with (OUT/(name+'.stdout')).open('w') as stdout, (OUT/(name+'.stderr')).open('w') as stderr:
        child = subprocess.Popen(list(map(str, arguments)), cwd=REPO, stdout=stdout, stderr=stderr,
                                 start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        finally:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            child.wait()
    print(name, 'exit', code, flush=True)
    return code

if os.environ.get('SKIP_OPERATOR_CHECKS') != '1':
    for name, args in [('operators', ['--mode','operator-parity']),
                       ('loader-ffn',['--mode','loader-parity','--partition','ffn']),
                       ('loader-full',['--mode','loader-parity','--partition','full'])]:
        code = command(name, [BUNDLE/'cluster-inference', *args, '--synthetic',
                             '--prompt-tokens','65','--chunk-size','32','--decode-tokens','8',
                             '--timeout-seconds','80'])
        records = [json.loads(line) for line in (OUT/(name+'.stdout')).read_text().splitlines() if line.startswith('{')]
        receipt['native_checks'].append(dict(name=name, exit_code=code,
            kinds=dict(collections.Counter(r['kind'] for r in records))))
        save()
        if code: raise SystemExit('Native checks failed: '+name)
save()

for dtype, teacher in [('float32', False), ('bfloat16', True), ('bfloat16', False)]:
    group = dtype + ('-teacher' if teacher else '-greedy')
    for backend in ['solo', 'loopback-test']:
        name = group + ('-solo' if backend == 'solo' else '-full')
        workload = dict(synthetic=True, synthetic_dtype=dtype, prompt_tokens=65, chunk_size=32,
                        decode_tokens=8, warmups=1, repeats=2, seed=7)
        if teacher: workload['teacher_tokens'] = [12, 25, 38, 51, 64, 77, 90]
        spec = dict(schema_version=1, backend=backend,
                    ranks=[dict(location='local')] * (1 if backend == 'solo' else 2),
                    workload=workload, capture_logits=True, timeout_seconds=45)
        if backend != 'solo': spec['partition'] = 'full'
        path = OUT/(name+'.spec.json'); path.write_text(json.dumps(spec, indent=2)+'\n')
        code = command(name, [sys.executable, CLUSTER/'run_inference.py', '--spec', path,
                              '--bundle', BUNDLE, '--output', OUT/name], 60)
        run = json.loads((OUT/name/'run.json').read_text())
        receipt['executions'].append(dict(name=name, exit_code=code,
            verified=run.get('verified_execution', False),
            bundle_sha256=run.get('bundle_manifest_sha256'),
            hardware_throughput_candidate=run.get('hardware_throughput_candidate', False)))
        save()
        if code: raise SystemExit('Execution failed: '+name)
    reference = json.loads((OUT/(group+'-solo')/'rank-0/logits.json').read_text())
    solo_run = json.loads((OUT/(group+'-solo')/'run.json').read_text())
    full_run = json.loads((OUT/(group+'-full')/'run.json').read_text())
    solo_report = solo_run['reports'][0]
    assert len(reference) == 8
    for rank in range(2):
        candidate = json.loads((OUT/(group+'-full')/f'rank-{rank}/logits.json').read_text())
        report = full_run['reports'][rank]
        for field in ['configurationSHA256','promptSHA256','teacherSHA256','embeddingActivationDType','ffnScaleDTypes']:
            assert report.get(field) == solo_report.get(field), field
        left_inputs = solo_report['runs'][-1]['decodeInputTokens']
        right_inputs = report['runs'][-1]['decodeInputTokens']
        rows = []
        for index, (left, right) in enumerate(zip(reference, candidate, strict=True)):
            assert len(left) == len(right) == 512 and all(map(math.isfinite, left+right))
            diff = [a-b for a,b in zip(left,right,strict=True)]
            top = sorted(range(len(left)), key=left.__getitem__, reverse=True)[:2]
            rows.append(dict(max_absolute_error=max(map(abs,diff)),
                relative_rms_error=math.sqrt(math.fsum(x*x for x in diff)/math.fsum(x*x for x in left)),
                histories_equal=left_inputs[:index] == right_inputs[:index],
                argmax_equal=top[0] == max(range(len(right)),key=right.__getitem__),
                reference_top_two_margin=left[top[0]]-left[top[1]]))
        record = dict(group=group, rank=rank, compared_values=sum(map(len, reference)), rows=rows,
                      controlled_history=teacher, bf16_qualification=False,
                      logit_capture_iteration=solo_report['runs'][-1]['iteration'],
                      rank_local_argmax_disagreement_counts=[r['localArgmaxDisagreementCount'] for r in report['runs']],
                      generated_tokens=report['runs'][-1]['generatedTokens'],
                      baseline_generated_tokens=solo_report['runs'][-1]['generatedTokens'])
        if dtype == 'float32':
            record['passed'] = all(r['max_absolute_error'] < 1e-3 and r['relative_rms_error'] < 1e-4
                                   and r['argmax_equal'] for r in rows)
        receipt['parity'].append(record); save()
        if record.get('passed') is False: raise SystemExit('F32 parity failed')
print('Validation evidence:', OUT/'receipt.json', flush=True)
