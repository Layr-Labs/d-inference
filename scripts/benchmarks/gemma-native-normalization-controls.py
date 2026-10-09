#!/usr/bin/env python3
"""Counterbalanced original/candidate Gemma controls; synthetic inputs only."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import time
import uuid


CONTROL_CELLS = ((128, 1), (128, 2), (4096, 1), (4096, 2))


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def validate_images(images):
    receipts = {
        arm: json.loads((path / 'build-receipt.json').read_text())
        for arm, path in images.items()
    }
    if receipts['native'].get('original_native_normalizer') is not True:
        raise RuntimeError('native image must retain the original normalizer')
    if receipts['candidate'].get('original_native_normalizer') is not False:
        raise RuntimeError('candidate image must declare the experimental normalizer')
    if receipts['native'].get('metallib_sha256') != receipts['candidate'].get('metallib_sha256'):
        raise RuntimeError('native and candidate metallib identities differ')
    for arm, path in images.items():
        receipt = receipts[arm]
        if receipt.get('token_receipts') is not True:
            raise RuntimeError(f'{arm} image lacks complete token receipt support')
        for filename, field in [
            ('BenchCBv2', 'benchmark_binary_sha256'), ('mlx.metallib', 'metallib_sha256')
        ]:
            if sha256_file(path / filename) != receipt.get(field):
                raise RuntimeError(f'{arm} {filename} does not match its build receipt')
    return receipts


def complete_cell_receipt(report_text, name, batch, prompt_length, steps=64):
    marker = f'- optimization-cell-json [perf/v2/B{batch}]: '
    serialized = [
        line[len(marker):] for line in report_text.splitlines() if line.startswith(marker)
    ]
    if len(serialized) != 1:
        raise RuntimeError(f'{name} missing unique cell receipt')
    cell = json.loads(serialized[0])
    receipts = cell.get('tokenReceipts')
    if cell.get('engine') != 'v2' or cell.get('batch') != batch:
        raise RuntimeError(f'{name} mismatched engine or batch receipt')
    if not isinstance(receipts, list) or len(receipts) != batch:
        raise RuntimeError(f'{name} missing complete output identity')
    for receipt in receipts:
        if not isinstance(receipt, dict):
            raise RuntimeError(f'{name} invalid request receipt')
        token_ids = receipt.get('tokenIDs')
        finish_reason = receipt.get('finishReason')
        if (not isinstance(token_ids, list) or len(token_ids) != steps
                or any(type(token) is not int or token < 0 for token in token_ids)
                or not isinstance(finish_reason, str) or not finish_reason
                or type(receipt.get('completionTokens')) is not int
                or receipt['completionTokens'] != steps
                or type(receipt.get('promptTokens')) is not int
                or receipt['promptTokens'] != prompt_length):
            raise RuntimeError(f'{name} incomplete generation identity')
    for field in ['itlP50Ms', 'ttftP50Ms']:
        value = cell.get(field)
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise RuntimeError(f'{name} invalid {field} timing')
    return cell


@contextmanager
def model_lease(lock, label):
    """Release only the lease whose unique owner this invocation published."""
    lock.mkdir()
    owner_path = lock / 'owner'
    owner = f'{label} {uuid.uuid4()}'
    try:
        owner_path.write_text(owner + '\n')
        yield
    finally:
        try:
            current_owner = owner_path.read_text().strip()
        except FileNotFoundError:
            current_owner = None
        if current_owner == owner:
            owner_path.unlink()
            lock.rmdir()


def summarize_controls(rows):
    expected = {(arm, repeat) for arm in ['native', 'candidate'] for repeat in range(3)}
    if len(rows) != 24:
        raise RuntimeError('control summary requires all 24 process cells')
    for length, batch in CONTROL_CELLS:
        selected = [row for row in rows if (row['length'], row['batch']) == (length, batch)]
        if len(selected) != 6 or {(row['arm'], row['repeat']) for row in selected} != expected:
            raise RuntimeError(f'L{length}-B{batch} missing unique native/candidate pairs')
    comparisons = []
    stable = True
    for length, batch in CONTROL_CELLS:
        chosen = [r for r in rows if (r['length'], r['batch']) == (length, batch)]
        native = [r['cell'] for r in chosen if r['arm'] == 'native']
        stable = stable and all(n['tokenReceipts'] == native[0]['tokenReceipts'] for n in native)
        for repeat in range(3):
            pair = {r['arm']: r['cell'] for r in chosen if r['repeat'] == repeat}
            comparisons.append({'length': length, 'batch': batch, 'repeat': repeat,
                                'tokens_equal': pair['native']['tokenReceipts'] == pair['candidate']['tokenReceipts'],
                                'itl_ratio': pair['candidate']['itlP50Ms'] / pair['native']['itlP50Ms'],
                                'ttft_ratio': pair['candidate']['ttftP50Ms'] / pair['native']['ttftP50Ms']})
    cell_checks = []
    for length, batch in CONTROL_CELLS:
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
    return summary


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
    receipts = validate_images(images)
    prereg = {
        'images': receipts,
        'model_config_sha256': sha256_file(args.model / 'config.json'),
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
    label = ('gemma-normalization-controls '
             + receipts['native']['sdk_revision'][:7] + ' '
             + receipts['candidate']['sdk_revision'][:7])
    rows = []
    with model_lease(lock, label):
        for cell_index, (length, batch) in enumerate(CONTROL_CELLS):
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
                    cell = complete_cell_receipt(
                        report.read_text(), name, batch, length)
                    row = {'arm': arm, 'length': length, 'batch': batch, 'repeat': repeat,
                           'started': started, 'finished': time.time(), 'argv': argv, 'cell': cell}
                    rows.append(row)
                    (args.out / 'runs.json').write_text(json.dumps(rows, indent=2))
                    print(f'{len(rows)}/24 {name}: ITL {cell["itlP50Ms"]:.3f} ms', flush=True)
    summary = summarize_controls(rows)
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
