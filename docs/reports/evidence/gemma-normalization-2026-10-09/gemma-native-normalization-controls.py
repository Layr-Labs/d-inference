#!/usr/bin/env python3
"""Counterbalanced original/candidate Gemma controls; synthetic inputs only."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import time


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    config = json.loads((args.model / 'config.json').read_text())
    if config.get('model_type') not in ['gemma4', 'gemma4_text']:
        raise RuntimeError('This campaign is qualified only for Gemma 4')
    args.out.mkdir(parents=True, exist_ok=True)
    images = {'native': args.native, 'candidate': args.candidate}
    receipts = {arm: json.loads((path / 'build-receipt.json').read_text())
                for arm, path in images.items()}
    assert receipts['native']['original_native_normalizer'] is True
    assert receipts['candidate']['original_native_normalizer'] is False
    assert receipts['native']['metallib_sha256'] == receipts['candidate']['metallib_sha256']
    for arm, path in images.items():
        assert sha(path / 'BenchCBv2') == receipts[arm]['benchmark_binary_sha256']
        assert sha(path / 'mlx.metallib') == receipts[arm]['metallib_sha256']
    prereg = {
        'images': receipts,
        'model_config_sha256': sha(args.model / 'config.json'),
        'model_path': str(args.model),
        'weight_inventory': [{'name': p.name, 'bytes': p.stat().st_size,
                              'mtime_ns': p.stat().st_mtime_ns}
                             for p in sorted(args.model.glob('*.safetensors'))],
        'prompt_lengths': [128, 4096], 'batches': [1, 2],
        'steps': 64, 'prefill_chunk': 512, 'pairs_per_cell': 3,
        'input': 'BenchCBv2 seeded syntheticPrompt, seed FACE plus request index',
        'quality_gate': 'every token ID, finish reason, prompt and completion count equal; native repeats stable',
        'benefit_gate': 'geometric mean ITL improves at least 1 percent; every cell median ITL and TTFT regresses at most 2 percent',
        'failure_action': 'evidence only; no runtime default change',
        'claim_limit': 'synthetic continuation identity; no task score or KV storage reduction claim',
    }
    (args.out / 'preregistration.json').write_text(json.dumps(prereg, indent=2))
    lock = Path('/tmp/darkbloom-kv-heavy.lock')
    lock.mkdir()
    owner = 'gemma-normalization-controls 45fedc1 f4fb61c'
    (lock / 'owner').write_text(owner + '\n')
    rows = []
    try:
        for cell_index, (length, batch) in enumerate([(128, 1), (128, 2), (4096, 1), (4096, 2)]):
            for repeat in range(3):
                arms = ['native', 'candidate'] if (cell_index + repeat) % 2 == 0 else ['candidate', 'native']
                for arm in arms:
                    name = f'L{length}-B{batch}-R{repeat}-{arm}'
                    report = args.out / (name + '.md')
                    argv = [str(images[arm] / 'BenchCBv2'), '--model', str(args.model),
                            '--mode', 'perf', '--engines', 'v2', '--batches', str(batch),
                            '--steps', '64', '--prompt-lengths', str(length), '--prefill-chunk', '512',
                            '--label', name, '--out', str(report)]
                    started = time.time()
                    with (args.out / (name + '.log')).open('w') as log:
                        completed = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT)
                    if completed.returncode != 0:
                        raise RuntimeError(f'{name} exit {completed.returncode}')
                    marker = f'- optimization-cell-json [perf/v2/B{batch}]: '
                    serialized = [line[len(marker):] for line in report.read_text().splitlines()
                                  if line.startswith(marker)]
                    if len(serialized) != 1:
                        raise RuntimeError(f'{name} missing unique cell receipt')
                    cell = json.loads(serialized[0])
                    tokens = cell.get('tokenReceipts')
                    if tokens is None or len(tokens) != batch:
                        raise RuntimeError(f'{name} missing complete output identity')
                    if any(len(r['tokenIDs']) != 64 or r['completionTokens'] != 64
                           or r['promptTokens'] != length for r in tokens):
                        raise RuntimeError(f'{name} incomplete generation')
                    row = {'arm': arm, 'length': length, 'batch': batch, 'repeat': repeat,
                           'started': started, 'finished': time.time(), 'argv': argv, 'cell': cell}
                    rows.append(row)
                    (args.out / 'runs.json').write_text(json.dumps(rows, indent=2))
                    print(f'{len(rows)}/24 {name}: ITL {cell["itlP50Ms"]:.3f} ms', flush=True)
    finally:
        if (lock / 'owner').read_text().strip() == owner:
            (lock / 'owner').unlink()
            lock.rmdir()
    comparisons = []
    stable = True
    for length, batch in [(128, 1), (128, 2), (4096, 1), (4096, 2)]:
        chosen = [r for r in rows if (r['length'], r['batch']) == (length, batch)]
        native = [r['cell'] for r in chosen if r['arm'] == 'native']
        candidate = [r['cell'] for r in chosen if r['arm'] == 'candidate']
        stable = stable and all(n['tokenReceipts'] == native[0]['tokenReceipts'] for n in native)
        for repeat in range(3):
            pair = {r['arm']: r['cell'] for r in chosen if r['repeat'] == repeat}
            comparisons.append({'length': length, 'batch': batch, 'repeat': repeat,
                                'tokens_equal': pair['native']['tokenReceipts'] == pair['candidate']['tokenReceipts'],
                                'itl_ratio': pair['candidate']['itlP50Ms'] / pair['native']['itlP50Ms'],
                                'ttft_ratio': pair['candidate']['ttftP50Ms'] / pair['native']['ttftP50Ms']})
    cell_checks = []
    for length, batch in [(128, 1), (128, 2), (4096, 1), (4096, 2)]:
        pair = [r for r in comparisons if (r['length'], r['batch']) == (length, batch)]
        cell_checks.append({'length': length, 'batch': batch,
                            'median_itl_ratio': statistics.median(r['itl_ratio'] for r in pair),
                            'median_ttft_ratio': statistics.median(r['ttft_ratio'] for r in pair)})
    geomean = math.exp(statistics.mean(math.log(r['itl_ratio']) for r in comparisons))
    quality = stable and all(r['tokens_equal'] for r in comparisons)
    benefit = geomean <= .99 and all(r['median_itl_ratio'] <= 1.02 and r['median_ttft_ratio'] <= 1.02 for r in cell_checks)
    summary = {'native_repeats_stable': stable, 'quality_gate': quality,
               'benefit_gate': benefit, 'geomean_itl_ratio': geomean,
               'cells': cell_checks, 'pairs': comparisons}
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
