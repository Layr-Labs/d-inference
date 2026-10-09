#!/usr/bin/env python3
"""Bounded CPU raw-basis encoding/restoration of public native KV packets."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import numpy as np

D = 512
ROTATED = np.r_[np.arange(64), np.arange(256, 320)]
UNROTATED = np.r_[np.arange(64, 256), np.arange(320, 512)]
TILE_ROWS = 8
HOST_CHARGE = 20 << 20


def bf16_product(values, gamma):
    # Products of two finite BF16 operands have at most16 significand bits,
    # so FP32 multiplication is exact before the one BF16 ties-to-even round.
    value_f32 = (values.astype(np.uint32) << 16).view(np.float32)
    gamma_f32 = (gamma.astype(np.uint32) << 16).view(np.float32)
    product = value_f32 * gamma_f32
    if not np.isfinite(product).all():
        raise ValueError('nonfinite arithmetic is not eligible for this prototype')
    words = product.view(np.uint32)
    rounded = words + np.uint32(0x7FFF) + ((words >> 16) & 1)
    return (rounded >> 16).astype('<u2')


def exact_read(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError('truncated native tile')
    return data


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(65536), b''):
            hasher.update(data)
    return hasher.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--packets', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    receipt = json.loads((args.packets / 'receipt.json').read_text())
    if receipt['model_aggregate_sha256'] != '2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785':
        raise ValueError('loaded-model identity mismatch')
    args.out.mkdir(parents=True, exist_ok=True)
    results = []
    for relation in receipt['relations']:
        layer, phase = relation['layer'], relation['phase']
        if not relation['dtype_match'] or not relation['unrotated_native_bit_identity']:
            raise ValueError('actual native relation was not proved')
        gamma_path = args.packets / f'L{layer}-Gamma.bin'
        if digest(gamma_path) != relation['gamma_sha256']:
            raise ValueError('loaded Gamma identity mismatch')
        gamma = np.frombuffer(gamma_path.read_bytes(), dtype='<u2')
        if gamma.shape != (D,):
            raise ValueError('Gamma shape mismatch')
        pair = {r['role']: r for r in receipt['records'] if r['layer'] == layer and r['phase'] == phase and r['role'] in ['keys', 'values']}
        if len(pair) != 2 or pair['keys']['dtype'] != 'bfloat16' or pair['values']['dtype'] != 'bfloat16':
            raise ValueError('raw-native BF16 pair required')
        if pair['keys']['shape'] != pair['values']['shape'] or pair['keys']['shape'][-1] != D:
            raise ValueError('paired native shape mismatch')
        original_k = args.packets / pair['keys']['file']
        original_v = args.packets / pair['values']['file']
        if digest(original_k) != pair['keys']['sha256'] or digest(original_v) != pair['values']['sha256']:
            raise ValueError('native packet identity mismatch')
        rows = original_k.stat().st_size // (2 * D)
        rotated_path = args.out / f'{phase}-L{layer}-Krot.bin'
        value_path = args.out / f'{phase}-L{layer}-V.bin'
        started = time.perf_counter()
        with original_k.open('rb') as keys, original_v.open('rb') as values, rotated_path.open('wb') as rotated, value_path.open('wb') as saved_v:
            remaining = rows
            while remaining:
                count = min(TILE_ROWS, remaining)
                k_data, v_data = exact_read(keys, count * D * 2), exact_read(values, count * D * 2)
                k = np.frombuffer(k_data, dtype='<u2').reshape(count, D)
                v = np.frombuffer(v_data, dtype='<u2').reshape(count, D)
                derived = bf16_product(v, gamma)
                if not np.array_equal(k[:, UNROTATED], derived[:, UNROTATED]):
                    raise ValueError('encode rejects native words that do not factor exactly')
                rotated.write(k[:, ROTATED].astype('<u2').tobytes())
                saved_v.write(v_data)
                remaining -= count
        encode_seconds = time.perf_counter() - started
        restored_k, restored_v = args.out / f'{phase}-L{layer}-restored-K.bin', args.out / f'{phase}-L{layer}-restored-V.bin'
        traffic = 0
        started = time.perf_counter()
        # Sequential K destination, using one independently referenced V tile.
        with rotated_path.open('rb') as rotated, value_path.open('rb') as values, restored_k.open('wb') as destination:
            remaining = rows
            while remaining:
                count = min(TILE_ROWS, remaining)
                r_data, v_data = exact_read(rotated, count * 128 * 2), exact_read(values, count * D * 2)
                traffic += len(r_data) + len(v_data)
                r = np.frombuffer(r_data, dtype='<u2').reshape(count, 128)
                v = np.frombuffer(v_data, dtype='<u2').reshape(count, D)
                k = bf16_product(v, gamma)
                k[:, ROTATED] = r
                destination.write(k.astype('<u2').tobytes())
                remaining -= count
        # The native sequential importer subsequently consumes V: charged reread.
        with value_path.open('rb') as values, restored_v.open('wb') as destination:
            remaining = rows * D * 2
            while remaining:
                data = exact_read(values, min(remaining, TILE_ROWS * D * 2))
                traffic += len(data)
                destination.write(data)
                remaining -= len(data)
        restore_seconds = time.perf_counter() - started
        exact = digest(restored_k) == pair['keys']['sha256'] and digest(restored_v) == pair['values']['sha256']
        if not exact:
            raise ValueError('restoration lost native identity')
        native_bytes = original_k.stat().st_size + original_v.stat().st_size
        stored_bytes = rotated_path.stat().st_size + value_path.stat().st_size
        # Six native-width tile arrays, five widened FP32 arrays, one Krot tile,
        # read/write byte copies and index/Gamma tables fit this conservative bound.
        tile_bound = TILE_ROWS * D * (6 * 2 + 5 * 4 + 4 * 2) + 65536
        if tile_bound > HOST_CHARGE:
            raise ValueError('charged host bound exceeded')
        results.append({'layer': layer, 'phase': phase, 'rows': rows,
                        'native_bytes': native_bytes, 'stored_basis_bytes': stored_bytes,
                        'stored_basis_ratio': stored_bytes / native_bytes,
                        'restore_read_bytes': traffic, 'restore_traffic_ratio': traffic / native_bytes,
                        'native_bit_identity': exact, 'encode_seconds': encode_seconds,
                        'restore_seconds': restore_seconds, 'host_charge_bytes': HOST_CHARGE,
                        'conservative_tile_bound_bytes': tile_bound})
    summary = {'scope': 'actual short native packets; CPU raw-file prototype, no encryption/production import performance claim',
               'sequential_import': 'K first, V second; independently referenced V reads, no random destination writes',
               'results': results, 'all_native_bits_restored': all(r['native_bit_identity'] for r in results)}
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
