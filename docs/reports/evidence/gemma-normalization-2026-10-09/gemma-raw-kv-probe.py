#!/usr/bin/env python3
"""Bounded Gemma 4 raw-projection operator experiment, never a serving switch.

Uses the real global-layer RMS weight with deterministic synthetic projections.
Does not load model weights, generate tokens, or establish model quality.
"""

import argparse
import hashlib
import json
import statistics
import struct
import time
from pathlib import Path

import mlx.core as mx
import numpy as np


def load_norm(directory: Path, layer: int) -> tuple[mx.array, str]:
    name = f"language_model.model.layers.{layer}.self_attn.k_norm.weight"
    index = json.loads((directory / "model.safetensors.index.json").read_text())["weight_map"]
    with (directory / index[name]).open("rb") as source:
        length = struct.unpack("<Q", source.read(8))[0]
        descriptor = json.loads(source.read(length))[name]
        start, stop = descriptor["data_offsets"]
        source.seek(8 + length + start)
        payload = source.read(stop - start)
    assert descriptor["shape"] == [512] and descriptor["dtype"] == "BF16"
    floats = (np.frombuffer(payload, dtype="<u2").astype(np.uint32) << 16).view(np.float32)
    return mx.array(floats).astype(mx.bfloat16), hashlib.sha256(payload).hexdigest()


def transformed(raw: mx.array, norm: mx.array, frequencies: mx.array, offset: int):
    keys = mx.fast.rms_norm(raw, norm, 1e-6).transpose(0, 2, 1, 3)
    keys = mx.fast.rope(keys, 512, traditional=False, base=None, scale=1.0,
                        offset=offset, freqs=frequencies)
    values = mx.fast.rms_norm(raw, None, 1e-6).transpose(0, 2, 1, 3)
    return keys, values


def shared_normalization(raw, norm):
    values = mx.fast.rms_norm(raw, None, 1e-6)
    return values * norm, values


def attention(q: mx.array, keys: mx.array, values: mx.array):
    # FP32 accumulators with native BF16-normalized/rotated K and V; the
    # candidate deliberately preserves every transform's native rounding.
    grouped = q.astype(mx.float32).reshape(1, 2, 8, 1, 512)
    scores = grouped @ keys.astype(mx.float32)[:, :, None].swapaxes(-1, -2)
    maximum = mx.max(scores, axis=-1, keepdims=True)
    weights = mx.exp(scores - maximum)
    denominator = mx.sum(weights, axis=-1, keepdims=True)
    numerator = weights @ values.astype(mx.float32)[:, :, None]
    return maximum, denominator, numerator


def bounded_attention(q, raw, norm, frequencies, tile):
    maximum, denominator, numerator = None, None, None
    for start in range(0, raw.shape[1], tile):
        keys, values = transformed(raw[:, start:start + tile], norm, frequencies, start)
        part_max, part_denom, part_numer = attention(q, keys, values)
        if maximum is None:
            maximum, denominator, numerator = part_max, part_denom, part_numer
        else:
            next_max = mx.maximum(maximum, part_max)
            old_scale, new_scale = mx.exp(maximum - next_max), mx.exp(part_max - next_max)
            denominator = old_scale * denominator + new_scale * part_denom
            numerator = old_scale * numerator + new_scale * part_numer
            maximum = next_max
        # Bound graph lifetime and work buffers rather than constructing an
        # unevaluated chain over the whole context. This synchronization cost
        # belongs in the experiment; production would require a fused kernel.
        mx.eval(maximum, denominator, numerator)
    return (numerator / denominator).reshape(1, 16, 1, 512)


def measure(operation, repeats):
    mx.eval(operation())
    samples = []
    result = None
    for _ in range(repeats):
        start = time.perf_counter()
        result = operation()
        mx.eval(result)
        samples.append((time.perf_counter() - start) * 1_000)
    return result, statistics.median(samples)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--lengths", type=int, nargs="+", default=[1_024, 8_192, 32_768])
    parser.add_argument("--tile", type=int, default=512)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.tile <= 0 or args.repeats <= 0 or not all(0 < n <= 32_768 for n in args.lengths):
        parser.error("positive sizes and lengths no larger than 32,768 are required")
    norm, norm_hash = load_norm(args.model_directory, 5)
    frequencies = mx.concatenate([
        1_000_000 ** (mx.arange(0, 128, 2, dtype=mx.float32) / 512),
        mx.full((192,), float("inf"))])
    mx.random.seed(19)
    rows = []
    for length in args.lengths:
        raw = mx.random.normal((1, length, 2, 512)).astype(mx.bfloat16)
        queries = mx.random.normal((1, 16, 1, 512)).astype(mx.bfloat16)
        keys, values = transformed(raw, norm, frequencies, 0)
        mx.eval(raw, queries, keys, values)
        # Exact transform parity is separate from attention reduction order.
        tile_keys, tile_values = transformed(raw[:, :args.tile], norm, frequencies, 0)
        tile_equal = bool(mx.all(tile_keys == keys[:, :, :args.tile]).item()) and bool(
            mx.all(tile_values == values[:, :, :args.tile]).item())
        # The pinned RMS kernel rounds before learned scaling, so this
        # reuse is exact for matching dtypes; test rather than assume it.
        shortcut = mx.fast.rope((values * norm).astype(mx.bfloat16), 512, traditional=False,
                                base=None, scale=1.0, offset=0, freqs=frequencies)
        shortcut_changed = int(mx.sum(shortcut != keys).item())
        native_norm, native_norm_ms = measure(lambda: mx.concatenate([
            mx.fast.rms_norm(raw, norm, 1e-6), mx.fast.rms_norm(raw, None, 1e-6)
        ], axis=2), args.repeats)
        shared_norm, shared_norm_ms = measure(lambda: mx.concatenate(
            shared_normalization(raw, norm), axis=2), args.repeats)
        norm_equal = bool(mx.all(native_norm == shared_norm).item())
        native, native_ms = measure(lambda: mx.fast.scaled_dot_product_attention(
            queries, keys, values, scale=1.0), args.repeats)
        candidate, candidate_ms = measure(lambda: bounded_attention(
            queries, raw, norm, frequencies, args.tile), args.repeats)
        difference = mx.abs(native.astype(mx.float32) - candidate)
        rows.append({
            "length": length, "tile": args.tile,
            "raw_projection_bytes": raw.nbytes,
            "native_kv_bytes": keys.nbytes + values.nbytes,
            "transform_tile_bit_equal": tile_equal,
            "v_times_norm_changed_key_elements": shortcut_changed,
            "shared_normalization_bit_equal": norm_equal,
            "native_normalization_ms": native_norm_ms,
            "shared_normalization_ms": shared_norm_ms,
            "native_attention_ms": native_ms,
            "bounded_raw_attention_ms": candidate_ms,
            "slowdown": candidate_ms / native_ms,
            "attention_max_abs_error": float(mx.max(difference).item()),
            "attention_rms_error": float(mx.sqrt(mx.mean(difference * difference)).item()),
        })
        del raw, queries, keys, values, native, candidate, shortcut, native_norm, shared_norm
        mx.clear_cache()
    report = {
        "scope": "Gemma 4 26B global-layer operator fixture, synthetic projections",
        "model_quality_qualified": False,
        "production_default_changed": False,
        "mlx_version": mx.__version__, "device": mx.metal.device_info(),
        "k_norm_sha256": norm_hash, "dtype": "bfloat16", "rows": rows,
        "gate": "do not promote: bounded reconstruction requires a fused kernel and model validation",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
