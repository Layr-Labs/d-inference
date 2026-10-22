"""Nemotron Super image goldens, stage 2: reference normalized tensors.

Reads stage 1's `reference.json` and RGB8 rasters and writes `tensors.json`
next to the reference. Uses CPU PyTorch exactly as NVIDIA's
`NemotronH_Omni_Reasoning_V3ImageProcessor._preprocess` does (antialiased
bicubic `interpolate`, then `(t / 255 - mean) / std`), with the grid rule
executed from the pinned processor source's AST. Model code is not imported.

    python3 -I generate_tensors.py --fixtures <fixtures> --rasters <scratch> \
        --processor <evidence>/image_processing_nemotron_h_omni.py
"""

import argparse
import ast
import hashlib
import json
import math
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import torch
import torch.nn.functional as F

SAMPLES = 32


def grid_rule(source: Path):
    tree = ast.parse(source.read_text())
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef))
    method = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "_compute_target_patches")
    namespace = {"math": math}
    exec(compile(ast.Module(body=[method], type_ignores=[]), str(source), "exec"), namespace)
    return namespace["_compute_target_patches"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--rasters", type=Path, required=True)
    parser.add_argument("--processor", type=Path, required=True)
    args = parser.parse_args()
    torch.set_num_threads(1)
    rule = grid_rule(args.processor)
    config = json.loads((args.processor.parent / "preprocessor_config.json").read_text())
    settings = SimpleNamespace(patch_size=config["patch_size"], min_num_patches=config["min_num_patches"],
                               _downsample_factor=int(round(1 / config["downsample_ratio"])))
    # Single-image budget from `_preprocess`.
    factor = settings._downsample_factor
    budget = max((config["max_model_len"] - 4) * factor * factor, config["min_num_patches"])
    tokens_available = max(min(budget, config["max_num_patches"]), config["min_num_patches"])
    mean = torch.tensor(config["norm_mean"]).view(1, 3, 1, 1)
    std = torch.tensor(config["norm_std"]).view(1, 3, 1, 1)
    reference = json.loads((args.fixtures / "reference.json").read_text())
    tensors = []
    for case in reference["cases"]:
        w, h = case["width"], case["height"]
        wp, hp = rule(settings, SimpleNamespace(width=w, height=h), tokens_available)
        tw, th = wp * settings.patch_size, hp * settings.patch_size
        raw = (args.rasters / f"{case['name']}.rgb").read_bytes()
        assert hashlib.sha256(raw).hexdigest() == case["rgb_sha256"]
        arr = np.frombuffer(raw, np.uint8).reshape(h, w, 3)
        t = torch.from_numpy(arr.copy()).permute(2, 0, 1).unsqueeze(0).to(dtype=torch.float32)
        if t.shape[-2] != th or t.shape[-1] != tw:
            t = F.interpolate(t, size=(th, tw), mode="bicubic", align_corners=False, antialias=True)
        t = ((t / 255.0 - mean) / std).squeeze(0).flatten().numpy()
        count = t.size
        rng = np.random.default_rng(len(tensors))
        indices = sorted(set(np.linspace(0, count - 1, SAMPLES // 2).astype(int).tolist())
                         | set(rng.choice(count, SAMPLES // 2, replace=False).tolist()))
        values = t.astype(np.float64)
        tensors.append({
            "name": case["name"], "width_patches": wp, "height_patches": hp, "width": tw, "height": th,
            "tokens": wp * hp // (factor * factor), "count": int(count),
            "indices": indices,
            # Shortest round-trip float32 spelling; Swift parses each value back to Float.
            "values": [float(np.format_float_positional(t[i], unique=True)) for i in indices],
            "sum": float(values.sum()), "sum_squares": float((values * values).sum()),
            "min": float(t.min()), "max": float(t.max()),
        })
    receipt = {
        "generator": "scripts/nemotron-qualification/image-goldens/generate_tensors.py",
        "torch": torch.__version__, "numpy": np.__version__,
        "processor_sha256": hashlib.sha256(args.processor.read_bytes()).hexdigest(),
        "tokens_available": tokens_available, "tensors": tensors,
    }
    rows = ",\n".join(json.dumps(tensor, separators=(",", ":")) for tensor in receipt.pop("tensors"))
    header = json.dumps(receipt, indent=1)[:-2]
    (args.fixtures / "tensors.json").write_text(header + ',\n "tensors": [\n' + rows + "\n ]\n}\n")


if __name__ == "__main__":
    main()
