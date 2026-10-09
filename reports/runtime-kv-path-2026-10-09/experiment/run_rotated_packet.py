#!/usr/bin/env python3
"""Choose a numerical candidate with a bounded frozen one-operator CPU experiment.

No GPU, model weights, live provider, private prompt or production config access.
"""
from __future__ import annotations
import os
for thread_key in ('OPENBLAS_NUM_THREADS', 'OMP_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[thread_key] = '1'
import argparse
from datetime import datetime, timezone
import hashlib
import json
import platform
from pathlib import Path
import time
import numpy as np
import scipy
import packet_reference as reference
import rotated_scalar_codec as codec

SEED = 20261009
CANDIDATES = (
    ('native_rotation_control', 'control', 'control', 4),
    ('affine8_per_token', 'affine', 'affine', 8),
    ('affine4_per_token', 'affine', 'affine', 4),
    ('rotated4_kv_gaussian_codebook', 'nonuniform', 'nonuniform', 4),
    ('rotated8_kv_gaussian_codebook', 'nonuniform', 'nonuniform', 8),
    ('rotated4_k_gaussian_v_affine', 'nonuniform', 'affine', 4),
    ('block128_hadamard_k_affine4_v_affine4', 'rotated_affine128', 'affine', 4),
    ('block64_rotated4_kv_gaussian_codebook', 'nonuniform64', 'nonuniform64', 4),
)


def native_round(values):
    return reference.decode_bf16(reference.encode_bf16(values), values.shape)


def transform_tensor(values, method, bits, recent, seed):
    prefix = values.shape[-2] - min(recent, values.shape[-2])
    old, tail = values[:, :, :prefix, :], values[:, :, prefix:, :]
    started = time.perf_counter()
    if method == 'affine':
        restored, info = reference.quantize(old, bits, axis=-1)
    elif method == 'nonuniform' or method == 'nonuniform64':
        view = old
        if method == 'nonuniform64':
            if old.shape[-1] % 64:
                raise ValueError('block64 path requires exact blocks; generic padded path is separate')
            view = old.reshape(*old.shape[:-1], old.shape[-1] // 64, 64)
        payload = codec.encode(view, bits, seed)
        restored = codec.decode(payload).reshape(old.shape)
        info = payload.description()
        info['rotationGranularity'] = 'entire head' if method == 'nonuniform' else 'independent 64-channel blocks'
        info['normGranularity'] = 'one FP32 norm per vector per token per head' if method == 'nonuniform' else 'one FP32 norm per 64-channel block per token per head'
    elif method == 'rotated_affine128':
        dim = old.shape[-1]
        if dim % 128:
            raise ValueError('block128 candidate requires exact blocks; no silent padding')
        signs = codec.rotation_signs(128, seed)
        view = old.reshape(*old.shape[:-1], dim // 128, 128)
        rotated = codec.rotate(view, signs).reshape(old.shape)
        quantized, info = reference.quantize(rotated, bits, axis=-1)
        restored = codec.inverse_rotate(quantized.reshape(view.shape), signs, 128).reshape(old.shape)
        sign_bytes = np.packbits(signs > 0, bitorder='little').tobytes()
        info['storageBytes'] += len(sign_bytes) + 8
        info.update(rotationBlockSize=128, rotationSignBytes=len(sign_bytes), seedBytes=8,
                    rotationSignSHA256=codec.sha(sign_bytes), seed=seed,
                    normGranularity='none; existing affine scale+bias per64 rotated channels')
    elif method == 'control':
        signs = codec.rotation_signs(old.shape[-1], seed)
        restored = codec.inverse_rotate(codec.rotate(old, signs), signs, old.shape[-1])
        info = {'storageBytes': values.size * 2 - tail.size * 2,
                'control': 'unquantized FP32 forward/inverse rotation, then native BF16 round; no packed format'}
    else:
        raise ValueError(method)
    fp32 = np.concatenate((restored, tail), axis=-2)
    native = np.concatenate((native_round(restored), tail), axis=-2)
    # Recent native rows are bit-identical, not merely numerically close.
    assert reference.encode_bf16(native[:, :, prefix:, :]) == reference.encode_bf16(tail)
    info.update(method=method, recentNativeRows=tail.shape[-2], nativeResidualBytes=tail.size * 2,
                totalStorageBytes=info['storageBytes'] + tail.size * 2,
                beforeNativeRoundTensorError=reference.error(fp32, values),
                nativeBF16TensorError=reference.error(native, values),
                cpuEncodeDecodeRoundMsSingleObservation=(time.perf_counter() - started) * 1000)
    return fp32, native, info


def distortion(q, k, v, scale, original_k):
    rows = []
    for head in range(q.shape[1]):
        owner = head // (q.shape[1] // k.shape[1])
        logits = (k[0, owner] @ q[0, head, 0]) * np.float32(scale)
        base = (original_k[0, owner] @ q[0, head, 0]) * np.float32(scale)
        rows.append(reference.error(logits, base))
    return {'maximumLogitRMSEAcrossHeads': max(x['rmse'] for x in rows),
            'maximumLogitLinfAcrossHeads': max(x['linf'] for x in rows)}


def run(packet_dir, output):
    p, record, arrays, raws, scale, packet_hash = reference.load_packet(packet_dir)
    q, k, v, captured = (arrays[n] for n in ('queries', 'storedKeys', 'storedValues', 'output'))
    ref = reference.attention(q, k, v, scale)
    native_bytes = len(raws['storedKeys']) + len(raws['storedValues'])
    codebooks = {str(bits): codec.gaussian_codebook(bits)[1] for bits in (4, 8)}
    result = {
        'schema': 'darkbloom.rotated-kv-cpu-candidate.v1',
        'timestampUTC': datetime.now(timezone.utc).isoformat(),
        'scope': 'One archived public artificial benchmark; Qwen3.6 owner0/model3; single decode query; CPU-only.',
        'identity': p['identity'], 'packetSHA256': packet_hash,
        'tensorSHA256': {name: desc['sha256'] for name, desc in p['tensors'].items()},
        'sourceArchive': 'docs/reports/evidence/qwen36-owner0-packets-2026-09-06/payloads.tar.gz',
        'sourceArchiveSHA256': '0ad883a7d23b3de60643197446064e15fd91ac71ee759012f5ef4ebd25f30f81',
        'geometry': {**p['geometry'], 'kShape': list(k.shape), 'vShape': list(v.shape), 'qShape': list(q.shape),
                     'modelLayer': record['modelLayerIndex'], 'storageOwner': record['storageLayerIndex'], 'scale': scale},
        'numericalPolicy': {'rotation': 'PCG64 seeded sign mask + normalized signed FWHT', 'seed': SEED,
                            'codebook': 'Lloyd-Max for standard Gaussian; FP32 serialized centroids',
                            'norms': 'FP32 per old token/head/vector (or per64 block for explicit block64 candidate)',
                            'nativeTailTokens': [0, 128], 'QJLResidualCorrection': False,
                            'fullTurboQuantImplementation': False,
                            'quantizedAttentionDomain': 'reconstructed original basis; separate FP32 and native BF16 references'},
        'codebooks': codebooks, 'baselineNativeKVBytes': native_bytes,
        'nativeCapturedOutputErrorVsUnmodifiedKVFP32': reference.error(captured, ref),
        'recent128AttentionMass': reference.recent_attention_mass(q, k, scale),
        'runtime': {'python': platform.python_version(), 'numpy': np.__version__, 'scipy': scipy.__version__,
                    'platform': platform.platform(), 'threads': 1, 'timing': 'single CPU observation; not native kernel/inference latency'},
        'limitations': [
            'No whole-model accuracy, logits, generation, perplexity, retrieval or all-model quality evaluation.',
            'No Metal kernel, live compressed KV allocation, native cache adoption, SSD integration or runtime throughput qualification.',
            'The artificial repetitive prompt and one layer/query are not representative production traffic.',
            'Norm-separated signed-Hadamard Gaussian quantization is MSE-style only: not Haar rotation, exact finite-dimensional Beta codebook or QJL-corrected TurboQuant.',
            'Explicit block64 is a different quantizer with extra per-block FP32 norms; block128 key affine uses per64 affine parameters.',
            'Recent128 is kept native; small128-token windows would receive no compression under that policy.',
            'Byte counts include packed codes, FP32 parameters/norms, actual sign masks, uint64 seeds, actual FP32 codebooks and codec manifest. DBK3/AES and allocator page overhead excluded.',
            'Shared-KV borrowers require one encoded payload per actual owner; no sharing is synthesized by this single-owner experiment.',
            'Recurrent, conv/SSM, MTP, diffusion latent state and other auxiliary state remain native and are absent from the measured savings.',
            'Positive non-power-of-two dimensions use a generic explicit zero-pad/full-inverse/crop path; current D192 may instead use exactly3 block64 tiles without padding.'
        ], 'variants': []}
    for name, key_method, value_method, bits in CANDIDATES:
        for recent in (0, 128):
            tensors = {}; decoded_fp32 = []; restored_native = []
            for role, original, method, seed in [('keys', k, key_method, SEED), ('values', v, value_method, SEED + 1)]:
                fp32, native, info = transform_tensor(original, method, bits, recent, seed)
                tensors[role] = info; decoded_fp32.append(fp32); restored_native.append(native)
            fp32_out = reference.attention(q, *decoded_fp32, scale)
            native_out = reference.attention(q, *restored_native, scale)
            heads = [reference.error(native_out[0, h], ref[0, h]) for h in range(q.shape[1])]
            storage = sum(x['totalStorageBytes'] for x in tensors.values())
            manifest = {'codec': name, 'bits': bits, 'seed': SEED, 'recentNativeRows': recent,
                        'kShape': list(k.shape), 'vShape': list(v.shape), 'codebookHash': codebooks[str(bits)]['serializedSHA256'],
                        'quantizationVersion': codec.VERSION, 'originalDType': 'bfloat16'}
            manifest_bytes = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
            row = {'candidate': name, 'bits': bits, 'recentNativeRows': recent, 'tensors': tensors,
                   'storageBytes': storage, 'codecManifestBytes': len(manifest_bytes),
                   'storageBytesWithManifest': storage + len(manifest_bytes), 'sizeReductionFraction': 1 - storage / native_bytes,
                   'operatorFP32ReconstructionError': reference.error(fp32_out, ref),
                   'operatorNativeBF16ReconstructionError': reference.error(native_out, ref),
                   'maximumHeadRelativeL2NativeBF16': max(x['relativeL2'] for x in heads),
                   'perHeadNativeBF16Error': heads, 'nativeLogitDistortion': distortion(q, *restored_native, scale, k)}
            result['variants'].append(row)
            print(name, recent, row['storageBytesWithManifest'], row['operatorNativeBF16ReconstructionError'], flush=True)
    result['experimentSourcesSHA256'] = {path.name: codec.sha(path.read_bytes()) for path in Path(__file__).parent.glob('*.py')}
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(output, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--packet', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.packet, args.output)
