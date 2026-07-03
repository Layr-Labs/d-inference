#!/usr/bin/env python3
"""Slice a DeepSeek-V4 MLX checkpoint down to its first N layers.

Produces a small (but REAL-weights) checkpoint that fits in RAM, for
validating the Swift port's load path + forward pass before expert
streaming exists. Keeps embeddings, norm, lm_head, and layers [0, N);
drops the MTP head. Rewrites config.json (num_hidden_layers,
compress_ratios, per-layer quantization keys) and the safetensors index.

The first 6 layers of DeepSeek-V4-Flash cover every architecture piece:
compress ratios [0, 0, 4, 128, 4, 128] (local + sparse + compressed
attention) and hash layers 0-2 + bias-routed MoE from layer 3.

usage: truncate-dsv4-checkpoint.py <src-dir> <dst-dir> [num-layers=6]
"""

import json
import shutil
import sys
from pathlib import Path

try:
    import mlx.core as mx
except ImportError:
    sys.exit("needs mlx (`pip install mlx`) — numpy safetensors can't represent bfloat16")


def layer_of(key: str):
    # model.layers.N.... or layers.N....
    parts = key.split(".")
    for i, p in enumerate(parts):
        if p == "layers" and i + 1 < len(parts):
            try:
                return int(parts[i + 1])
            except ValueError:
                return None
    return None


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    n_layers = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    dst.mkdir(parents=True, exist_ok=True)

    config = json.loads((src / "config.json").read_text())
    assert config.get("model_type") == "deepseek_v4", "not a deepseek_v4 checkpoint"

    def keep(key: str) -> bool:
        if key.startswith("mtp.") or ".mtp." in key:
            return False
        layer = layer_of(key)
        return layer is None or layer < n_layers

    index = json.loads((src / "model.safetensors.index.json").read_text())
    weight_map = index["weight_map"]
    kept = {k: v for k, v in weight_map.items() if keep(k)}
    print(f"keeping {len(kept)}/{len(weight_map)} tensors (layers 0..{n_layers - 1})")

    # Group kept tensors by source shard, write one output shard per source
    # shard that still has content.
    by_shard = {}
    for key, shard in kept.items():
        by_shard.setdefault(shard, []).append(key)

    new_map = {}
    total_bytes = 0
    for shard, keys in sorted(by_shard.items()):
        out_name = shard
        # mx.load is lazy; only the kept tensors are materialized by the save.
        loaded = mx.load(str(src / shard))
        tensors = {k: loaded[k] for k in keys}
        mx.save_safetensors(str(dst / out_name), tensors)
        del loaded, tensors
        mx.clear_cache()
        size = (dst / out_name).stat().st_size
        total_bytes += size
        for key in keys:
            new_map[key] = out_name
        print(f"  {out_name}: {len(keys)} tensors, {size / 1e9:.2f} GB", flush=True)

    (dst / "model.safetensors.index.json").write_text(json.dumps({
        "metadata": {"total_size": total_bytes},
        "weight_map": new_map,
    }, indent=2))

    # Rewrite config: layer count, compress ratios, hash layers, MTP off,
    # and drop per-layer quantization overrides for removed layers.
    config["num_hidden_layers"] = n_layers
    if isinstance(config.get("compress_ratios"), list):
        config["compress_ratios"] = config["compress_ratios"][:n_layers]
    config["num_hash_layers"] = min(config.get("num_hash_layers", 0), n_layers)
    config["num_nextn_predict_layers"] = 0
    quant = config.get("quantization")
    if isinstance(quant, dict):
        config["quantization"] = {
            k: v for k, v in quant.items()
            if layer_of(k) is None or layer_of(k) < n_layers
        }
        if "quantization_config" in config:
            config["quantization_config"] = config["quantization"]
    (dst / "config.json").write_text(json.dumps(config, indent=2))

    for aux in ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja",
                "generation_config.json", "special_tokens_map.json", "README.md"]:
        if (src / aux).exists():
            shutil.copy(src / aux, dst / aux)

    print(f"wrote {dst} ({total_bytes / 1e9:.2f} GB)")


if __name__ == "__main__":
    main()
