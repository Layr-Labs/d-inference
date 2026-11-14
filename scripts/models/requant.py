#!/usr/bin/env python3
"""requant.py: re-quantize the language-model linears of a published MLX build from the original bf16 weights,
keeping every other byte of the build (numpy on the CPU; no MLX, no GPU).

  requant.py verify --template URL --source URL [--limit N]
  requant.py plan   --template URL --recipe RECIPE
  requant.py build  --template URL --source URL --recipe RECIPE --out DIR
  requant.py selftest [--record]

- template: the published revision's base URL (models.darkbloom.ai/<r2_prefix>), range-read; its config.json,
  tokenizer and template files, vision tower, MTP head and every non-linear tensor are copied byte for byte.
- source: the original bf16 checkpoint's pinned base URL (huggingface.co/<repo>/resolve/<40-hex sha>), range-read one
  tensor at a time, so only the output lands on disk.
- Quantization mirrors MLX's affine_quantize and packing (power-of-two widths fill each uint32 from its lowest bits;
  3/5/6-bit values form one little-endian bit stream). Checked against MLX-written tensors at 4/64, 4/32, 5/64, 6/64
  and 8/64: 99.6-99.9 % of codes equal, the rest one step apart from one-ulp bf16 scale rounding.
- MoE experts: switch_mlp.{gate,up,down}_proj [E, out, in] come from the source's fused experts.gate_up_proj
  [E, 2I, H] (gate rows first) and experts.down_proj [E, H, I].
- verify re-quantizes modules at the template's own bits and compares codes, to prove the name mapping first.
- The output is deterministic for a given template, source, recipe and numpy (pinned by the workflow), so a build in
  CI reproduces a locally tested candidate byte for byte; the canonical manifest is the check.
- selftest (about a second, no network): quantizes fixed inputs at every recipe width and serializes them, and compares
  the digests with the recorded ones. Run it before any build, on every machine; a difference means this machine would
  not reproduce the tested bytes. --record prints this machine's digests.
- RECIPEs (bits, group) per module path; a module the template keeps above 4 bits (MoE routers) keeps it:
    g64       4/64 (the template's layout)        g32       4/32
    mixed46   6/64 for lm_head and for down_proj / v_proj in the first and last eighth of the layers and every third
              layer between (mlx-lm's mixed_4_6 rule); 4/64 elsewhere
    router8   8/64 for MoE routers (mlp.gate, mlp.shared_expert_gate); 4/64 elsewhere
    router8+mixed46   both
"""
import argparse, hashlib, json, os, platform, re, struct, sys, tempfile, time, urllib.error, urllib.request

import numpy as np

UA = {"User-Agent": "or-quality-requant/1"}


def get(url, start=None, end=None, tries=12):
    """GET, or a range of bytes start..end inclusive, with retries. A range read must return exactly the range: a server
    that ignores Range answers 200 with the whole object, which would otherwise be written as the tensor."""
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=dict(UA))
            if start is not None:
                req.add_header("Range", f"bytes={start}-{end}")
            with urllib.request.urlopen(req, timeout=300) as r:
                data = r.read()
            if start is not None and len(data) != end - start + 1:
                raise IOError(f"range {start}-{end} of {url}: {len(data)} bytes")
            return data
        except Exception as e:  # noqa: BLE001
            if i == tries - 1:
                raise
            wait = retry_wait(e, i)
            if isinstance(e, urllib.error.HTTPError):
                e.close()
            time.sleep(wait)


def retry_wait(e, i):
    """Seconds before retry i + 1. 429 and 503 wait for Retry-After, else back off for minutes: Hugging Face limits
    anonymous requests per IP over 5-minute windows, and CI runners share egress IPs."""
    if isinstance(e, urllib.error.HTTPError) and e.code in (429, 503):
        after = (e.headers.get("Retry-After") or "").strip()
        return min(int(after), 600) if after.isdigit() else min(30 * 2 ** i, 600)
    return min(2 + 3 * i, 60)


class RemoteST:
    """One remote safetensors file: header by range, tensors by range."""

    def __init__(self, url):
        self.url = url
        n = struct.unpack("<Q", get(url, 0, 7))[0]
        self.header = json.loads(get(url, 8, 8 + n - 1))
        self.base = 8 + n
        self.meta = self.header.pop("__metadata__", None)

    def raw(self, name):
        info = self.header[name]
        a, b = info["data_offsets"]
        return get(self.url, self.base + a, self.base + b - 1) if b > a else b""

    def info(self, name):
        return self.header[name]


class RemoteModel:
    def __init__(self, base):
        self.base = base.rstrip("/")
        idx = json.loads(get(self.base + "/model.safetensors.index.json"))
        self.wmap = idx["weight_map"]
        self.files = {}

    def file(self, fname):
        if fname not in self.files:
            self.files[fname] = RemoteST(self.base + "/" + fname)
        return self.files[fname]

    def raw(self, name):
        return self.file(self.wmap[name]).raw(name)

    def info(self, name):
        return self.file(self.wmap[name]).info(name)


def bf16_to_f32(buf, shape):
    u = np.frombuffer(buf, dtype=np.uint16).astype(np.uint32) << 16
    return u.view(np.float32).reshape(shape)


def f32_to_bf16(x):
    u = np.ascontiguousarray(x, dtype=np.float32).view(np.uint32)
    r = ((u >> 16) & 1) + 0x7FFF
    return ((u + r) >> 16).astype(np.uint16)


def affine_quantize(w, bits, group, chunk_values=None):
    """MLX affine quantization of a 2-D float32 [out, in] (or 3-D [E, out, in]) array, in row chunks of about
    chunk_values values (64M by default; the selftest sets it small to cover the chunked path)."""
    rows = int(np.prod(w.shape[:-1]))
    chunk = max(1, (chunk_values or 1 << 26) // w.shape[-1])
    if rows > chunk:
        flat = w.reshape(rows, w.shape[-1])
        parts = [affine_quantize_rows(flat[i:i + chunk], bits, group) for i in range(0, rows, chunk)]
        pw = np.concatenate([p[0] for p in parts]).reshape(w.shape[:-1] + (-1,))
        ps = np.concatenate([p[1] for p in parts]).reshape(w.shape[:-1] + (-1,))
        pb = np.concatenate([p[2] for p in parts]).reshape(w.shape[:-1] + (-1,))
        return pw, ps, pb
    return affine_quantize_rows(w, bits, group)


def affine_quantize_rows(w, bits, group):
    shape = w.shape
    g = w.reshape(-1, shape[-1] // group, group)
    n_bins = float((1 << bits) - 1)
    w_max = g.max(axis=-1, keepdims=True)
    w_min = g.min(axis=-1, keepdims=True)
    mask = np.abs(w_min) > np.abs(w_max)
    scales = np.maximum((w_max - w_min) / n_bins, np.float32(1e-7)).astype(np.float32)
    scales = np.where(mask, scales, -scales)
    edge = np.where(mask, w_min, w_max)
    q0 = np.round(edge / scales)
    scales = np.where(q0 != 0, edge / np.where(q0 != 0, q0, 1), scales).astype(np.float32)
    biases = np.where(q0 == 0, np.float32(0), edge).astype(np.float32)
    q = np.clip(np.round((g - biases) / scales), 0, n_bins).astype(np.uint32)
    packed = pack(q.reshape(-1), bits)
    out_shape = shape[:-1] + (shape[-1] * bits // 32,)
    s_shape = shape[:-1] + (shape[-1] // group,)
    return packed.reshape(out_shape), f32_to_bf16(scales).reshape(s_shape), f32_to_bf16(biases).reshape(s_shape)


def pack(q, bits):
    """MLX's packing: power-of-two widths fill each uint32 from its lowest bits; 3/5/6 bits form one little-endian
    bit stream cut into uint32 words (ops.cpp pack_and_quantize)."""
    if 32 % bits == 0:
        per = 32 // bits
        q = q.reshape(-1, per)
        packed = np.zeros(q.shape[0], dtype=np.uint32)
        for i in range(per):
            packed |= q[:, i] << np.uint32(bits * i)
        return packed
    out = []
    step = 32 * 1024 * 1024  # values per chunk; a multiple of 32 keeps word boundaries
    for c in range(0, q.size, step):
        v = q[c:c + step]
        b = ((v[:, None] >> np.arange(bits, dtype=np.uint32)) & 1).astype(np.uint32).reshape(-1, 32)
        out.append((b << np.arange(32, dtype=np.uint32)).sum(axis=1, dtype=np.uint64).astype(np.uint32))
    return np.concatenate(out)


def unpack(packed, bits, n_in):
    p = packed.reshape(-1)
    if 32 % bits == 0:
        per = 32 // bits
        cols = [(p >> np.uint32(bits * i)) & np.uint32((1 << bits) - 1) for i in range(per)]
        q = np.stack(cols, axis=-1).reshape(-1)
    else:
        b = ((p[:, None] >> np.arange(32, dtype=np.uint32)) & 1).reshape(-1, bits)
        q = (b << np.arange(bits, dtype=np.uint32)).sum(axis=1).astype(np.uint32)
    return q.reshape(packed.shape[:-1] + (n_in,))


# ---- name mapping: our MLX names -> the HF source names ------------------------------------------------------------

def hf_name_dense(mod):
    if mod == "language_model.lm_head":
        return "lm_head.weight"
    return "model." + mod.replace("language_model.model.", "language_model.", 1) + ".weight"


def layer_index(path):
    m = re.search(r"\.layers\.(\d+)\.", path)
    return int(m.group(1)) if m else None


def recipe_for(recipe, mod, n_layers, template=(4, 64)):
    """(bits, group) for one module. A module the template already keeps above 4 bits (MoE routers at 8) keeps its
    template precision under every recipe."""
    if template[0] > 4:
        return template
    router = mod.endswith(".mlp.gate") or mod.endswith(".mlp.shared_expert_gate")
    if recipe == "g64":
        return 4, 64
    if recipe == "g32":
        return 4, 32
    if recipe == "router8":
        return (8, 64) if router else (4, 64)
    if recipe in ("mixed46", "router8+mixed46"):
        if router and recipe == "router8+mixed46":
            return 8, 64
        if mod.endswith("lm_head"):
            return 6, 64
        i = layer_index(mod)
        more = i is not None and (i < n_layers // 8 or i >= 7 * n_layers // 8 or (i - n_layers // 8) % 3 == 2)
        if more and (mod.endswith("down_proj") or mod.endswith("v_proj")):
            return 6, 64
        return 4, 64
    raise SystemExit(f"unknown recipe {recipe}")


def template_quant(tm, mod):
    """The template's (bits, group) for a module, from its config.json quantization block (a per-module entry, else
    the default); packed widths alone can't tell 4-bit g128 from 8-bit g64."""
    if not hasattr(tm, "_qcfg"):
        cfg = json.loads(get(tm.base + "/config.json"))
        tm._qcfg = cfg.get("quantization") or cfg.get("quantization_config") or {}
    q = tm._qcfg
    entry = q.get(mod) if isinstance(q.get(mod), dict) else None
    if entry is None:  # some builds key overrides without the leading "language_model."
        alt = mod.split(".", 1)[1] if "." in mod else mod
        entry = q.get(alt) if isinstance(q.get(alt), dict) else None
    entry = entry or q
    return int(entry.get("bits", q["bits"])), int(entry.get("group_size", q["group_size"]))


def template_bits(tm, mod, n_in=None):
    return template_quant(tm, mod)


def in_features(tm, mod):
    bits, group = template_quant(tm, mod)
    wi, si = tm.info(mod + ".weight"), tm.info(mod + ".scales")
    n_in = wi["shape"][-1] * 32 // bits
    assert n_in == si["shape"][-1] * group, (mod, wi["shape"], si["shape"], bits, group)
    return n_in


def quantized_modules(tm):
    mods = sorted(k[: -len(".scales")] for k in tm.wmap if k.endswith(".scales"))
    return [m for m in mods if m.startswith("language_model.")]


_cache = {}


def fetch_f32(sm, name):
    if name not in _cache:
        _cache.clear()  # keep one tensor: a fused expert tensor is read for two modules in a row
        info = sm.info(name)
        assert info["dtype"] == "BF16", (name, info["dtype"])
        _cache[name] = bf16_to_f32(sm.raw(name), tuple(info["shape"]))
    return _cache[name]


def source_weight(sm, mod):
    """The bf16 source of one of our quantized modules, as float32 [.., out, in].
    MoE experts: our switch_mlp.{gate,up,down}_proj [E, out, in] come from the source's fused
    experts.gate_up_proj [E, 2*I, H] (gate rows first, then up) and experts.down_proj [E, H, I]."""
    m = re.match(r"(language_model\.model\.layers\.\d+\.mlp)\.switch_mlp\.(gate|up|down)_proj$", mod)
    if m:
        base = "model." + m.group(1).replace("language_model.model.", "language_model.", 1) + ".experts."
        if m.group(2) == "down":
            return fetch_f32(sm, base + "down_proj")
        fused = fetch_f32(sm, base + "gate_up_proj")
        half = fused.shape[1] // 2
        return fused[:, :half, :] if m.group(2) == "gate" else fused[:, half:, :]
    return fetch_f32(sm, hf_name_dense(mod))


def cmd_verify(a):
    tm, sm = RemoteModel(a.template), RemoteModel(a.source)
    mods = quantized_modules(tm)
    pick = [m for m in mods if "embed_tokens" not in m][: a.limit]
    for mod in pick:
        t0 = time.time()
        winfo = tm.info(mod + ".weight")
        tw = np.frombuffer(tm.raw(mod + ".weight"), dtype=np.uint32).reshape(winfo["shape"])
        ts = np.frombuffer(tm.raw(mod + ".scales"), dtype=np.uint16).reshape(tm.info(mod + ".scales")["shape"])
        tb = np.frombuffer(tm.raw(mod + ".biases"), dtype=np.uint16).reshape(tm.info(mod + ".biases")["shape"])
        w = source_weight(sm, mod)
        bits = 32 * winfo["shape"][-1] // w.shape[-1]
        group = w.shape[-1] // ts.shape[-1]
        pw, ps, pb = affine_quantize(w, bits, group)
        same_codes = (unpack(pw, bits, w.shape[-1]) == unpack(tw, bits, w.shape[-1])).mean()
        print(f"{mod}: shape {w.shape} bits {bits} group {group} codes equal {same_codes:.5f} "
              f"scales equal {(ps == ts).mean():.5f} biases equal {(pb == tb).mean():.5f} ({time.time() - t0:.1f}s)",
              flush=True)


def cmd_plan(a):
    """Disk size and active bytes per decoded token of a recipe, from the template's headers alone (no source reads).
    Active: every linear but the embedding table; MoE experts count top_k / num_experts of their bytes."""
    tm = RemoteModel(a.template)
    cfg = json.loads(get(tm.base + "/config.json"))
    tc = cfg.get("text_config", cfg)
    n_layers, k, e = tc["num_hidden_layers"], tc.get("num_experts_per_tok", 1), tc.get("num_experts", 1)
    tot = {"template": [0, 0], a.recipe: [0, 0]}
    for mod in quantized_modules(tm):
        n_in = in_features(tm, mod)
        rows = int(np.prod(tm.info(mod + ".weight")["shape"][:-1]))
        params = rows * n_in
        frac = (k / e) if ".switch_mlp." in mod else (0 if mod.endswith("embed_tokens") else 1)
        tb = template_bits(tm, mod, n_in)
        for key, (bits, group) in (("template", tb), (a.recipe, recipe_for(a.recipe, mod, n_layers, tb))):
            bpp = bits / 8 + 4 / group  # packed bits + bf16 scale and bias per group
            tot[key][0] += params * bpp
            tot[key][1] += params * bpp * frac
    d0, a0 = tot["template"]
    d1, a1 = tot[a.recipe]
    print(f"{a.recipe}: quantized-linear bytes on disk {d0 / 1e9:.2f} -> {d1 / 1e9:.2f} GB ({(d1 / d0 - 1) * 100:+.1f} %); "
          f"active bytes per token {a0 / 1e9:.3f} -> {a1 / 1e9:.3f} GB ({(a1 / a0 - 1) * 100:+.1f} %; bandwidth-bound "
          f"decode >= {a0 / a1:.2f}x)")


def write_st(path, tensors):
    """tensors: list of (name, dtype_str, shape, bytes)."""
    header, off = {}, 0
    for name, dt, shape, buf in tensors:
        header[name] = {"dtype": dt, "shape": list(shape), "data_offsets": [off, off + len(buf)]}
        off += len(buf)
    header["__metadata__"] = {"format": "mlx"}
    h = json.dumps(header, separators=(",", ":")).encode()
    h += b" " * ((8 - len(h) % 8) % 8)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(h)))
        f.write(h)
        for _, _, _, buf in tensors:
            f.write(buf)


def cmd_build(a):
    tm, sm = RemoteModel(a.template), RemoteModel(a.source)
    os.makedirs(a.out, exist_ok=False)
    cfg = json.loads(get(tm.base + "/config.json"))
    n_layers = cfg.get("text_config", cfg)["num_hidden_layers"]
    manifest = json.loads(get(tm.base + "/manifest.json"))
    mods = set(quantized_modules(tm))
    overrides = {}
    # tensors of the main shards (model-*.safetensors), in the template's order; mtp-* files are copied whole
    main_files = sorted({f for f in tm.wmap.values() if f.startswith("model-")})
    names = [n for f in main_files for n in tm.file(f).header]
    out_tensors, shard, size, wmap, t0 = [], 1, 0, {}, time.time()
    limit = int(a.shard_gb * 1e9)
    pending = []

    def flush(final=False):
        nonlocal pending, shard, size
        if not pending:
            return
        fname = f"model-{shard:05d}-of-XXXXX.safetensors"
        write_st(os.path.join(a.out, fname), pending)
        for n, *_ in pending:
            wmap[n] = fname
        pending, size, shard = [], 0, shard + 1

    done = set()
    for n in names:
        mod = n.rsplit(".", 1)[0]
        if mod in mods:
            if mod in done:
                continue
            done.add(mod)
            n_in = in_features(tm, mod)
            bits, group = recipe_for(a.recipe, mod, n_layers, template_bits(tm, mod, n_in))
            w = source_weight(sm, mod)
            pw, ps, pb = affine_quantize(w, bits, group)
            for suffix, dt, arr in ((".weight", "U32", pw), (".scales", "BF16", ps), (".biases", "BF16", pb)):
                buf = arr.tobytes()
                pending.append((mod + suffix, dt, arr.shape, buf))
                size += len(buf)
            if (bits, group) != (4, a.base_group):
                overrides[mod] = {"group_size": group, "bits": bits, "mode": "affine"}
            print(f"[{time.time() - t0:7.0f}s] {mod} -> {bits}/{group}", flush=True)
        else:
            info = tm.info(n)
            buf = tm.raw(n)
            pending.append((n, info["dtype"], info["shape"], buf))
            size += len(buf)
        if size >= limit:
            flush()
    flush(final=True)
    total = shard - 1
    for i in range(1, total + 1):
        old = os.path.join(a.out, f"model-{i:05d}-of-XXXXX.safetensors")
        new = os.path.join(a.out, f"model-{i:05d}-of-{total:05d}.safetensors")
        os.rename(old, new)
    wmap = {k: v.replace("XXXXX", f"{total:05d}") for k, v in wmap.items()}
    # copy the non-main files byte for byte (mtp shards, tokenizer, templates, processor configs)
    for f in manifest["files"]:
        p = f["path"]
        if p.startswith("model-") or p in ("model.safetensors.index.json", "config.json"):
            continue
        data = get(tm.base + "/" + p)
        with open(os.path.join(a.out, p), "wb") as fh:
            fh.write(data)
        if p.endswith(".safetensors"):
            for n in RemoteST(tm.base + "/" + p).header:
                wmap[n] = p
    q = {"group_size": a.base_group, "bits": 4, "mode": "affine"}
    q.update(overrides)
    cfg["quantization"] = q
    cfg["quantization_config"] = q
    with open(os.path.join(a.out, "config.json"), "w") as fh:
        json.dump(cfg, fh, indent=2)
    total_size = sum(os.path.getsize(os.path.join(a.out, v)) for v in set(wmap.values()))
    with open(os.path.join(a.out, "model.safetensors.index.json"), "w") as fh:
        json.dump({"metadata": {"total_size": total_size}, "weight_map": dict(sorted(wmap.items()))}, fh, indent=2)
    print(f"done: {len(done)} modules re-quantized ({len(overrides)} overrides), {total} main shards, "
          f"{total_size / 1e9:.2f} GB, {time.time() - t0:.0f}s", flush=True)


# ---- selftest: the arithmetic, packing and serialization, against digests recorded with the pinned numpy -----------

SELFTEST_WIDTHS = ((4, 64), (4, 32), (6, 64), (8, 64))  # every (bits, group) a recipe produces
# sha256 of (packed, scales, biases) per case and width, and of the serialized safetensors + config + index bytes.
# Recorded with numpy 2.5.4 (Python 3.14.7, arm64, M5 Ultra); every quantization digest also equals the float64 oracle
# in test_model_requant_upload.py, which depends on no CPU, SIMD path or numpy version.
SELFTEST_GOLDEN = {
    "edges 4/32": "dd870292666f5555c3f558a7872a34e542cbc0dc6d225813ba08b643634507ed",
    "edges 4/64": "bacebc6a7e6e59a495b1a8d0e481871cd0c20c9d868ed4f82152bb7d13517539",
    "edges 6/64": "6510e0f9efd61c28ae42d0575da590562377aca3d37b858632374b7aa706b9a6",
    "edges 8/64": "c3f05982b43be0df6c2ff9f3179121545b6800a425174faaca30727fd4c9a568",
    "experts-gate-half 4/32": "38cf051133bbf80392c723d865cf6a1cc656d7b3a7b611c04f7e5657f7d16015",
    "experts-gate-half 4/64": "860019ee474807978f99d21a7d06cdc195fb359f6a46e09af1f54d35e0ccd811",
    "experts-gate-half 6/64": "3331a859b2cade43a2762f883ff21c8ecf8b4711b4a988836daf62ca74f7ed0d",
    "experts-gate-half 8/64": "ee0c8cf6f91421984ea983e8884843ccf0e6c05b69ea5c5356ce6a0009622783",
    "serialization": "655db5e1fefeb0f7a6970efbd534835b3fac2141988136ab6b6b25cfba3e3212",
    "weights 4/32": "fef56a45907a7d41fa794810acf1409dc51db4a93e89ebadc49494bf0263b2ba",
    "weights 4/64": "cc5f3af19f6ac327b90d6831a72d1e1c3738b09d6e4d9a44a708d4d002167985",
    "weights 6/64": "34a2397f5449e269870f9f4400399be76f34bc1f420630fc110ee72895435628",
    "weights 8/64": "4105b9ff7f0090dccadbf33496a9a2187698d56e2afdc506b3df47348598ee85",
}


def _bf16_bits(label, n):
    """n bf16 bit patterns from SHAKE-256 (as uint32): the same on every machine and numpy version."""
    return np.frombuffer(hashlib.shake_256(label.encode()).digest(2 * n), dtype="<u2").astype(np.uint32)


def selftest_cases():
    """name -> (float32 weights, chunk_values): weight-like values with outliers; edge cases (signed zeros, ties,
    subnormals, constant groups, ranges that overflow float32); and the gate half of a fused [E, 2I, H] expert tensor,
    a strided 3-D view, quantized in uneven row chunks (the MoE path)."""
    r = _bf16_bits("weights", 256 * 1024).reshape(256, 1024)
    exp = 117 + ((r >> 7) & 7) + 6 * ((np.arange(r.size).reshape(r.shape) % 97) == 0)  # 2^-10..2^-3, outliers 2^6 up
    weights = ((r & 0x8000) | (exp << 7) | (r & 0x7F)).astype(np.uint16)

    e = _bf16_bits("edges", 64 * 512).reshape(64, 512)
    e = np.where((e & 0x7F80) == 0x7F80, (e & 0x8000) | 0x3F80, e)  # finite only
    e[0] = 0
    e[1] = 0x8000
    e[2, ::2], e[2, 1::2] = 0, 0x8000
    e[3] = 0x3F80
    e[4] = 0x0001
    e[5, ::2], e[5, 1::2] = 0x0001, 0x8001
    e[6, ::2], e[6, 1::2] = 0x3F80, 0xBF80
    e[7] &= 0x807F  # subnormals of both signs
    e[8, ::2], e[8, 1::2] = 0x7F7F, 0xFF7F  # +-max finite: the range overflows to inf
    edges = e.astype(np.uint16)

    f = _bf16_bits("experts", 4 * 256 * 512).reshape(4, 256, 512)
    fexp = 118 + ((f >> 7) & 7)
    fused = ((f & 0x8000) | (fexp << 7) | (f & 0x7F)).astype(np.uint16)
    fused32 = bf16_to_f32(fused.tobytes(), fused.shape)
    return {"weights": (bf16_to_f32(weights.tobytes(), weights.shape), None),
            "edges": (bf16_to_f32(edges.tobytes(), edges.shape), None),
            "experts-gate-half": (fused32[:, :128, :], 48 * 512)}


def _digest(parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(np.ascontiguousarray(p).tobytes())
    return h.hexdigest()


def selftest_digests():
    out, cases = {}, selftest_cases()
    with np.errstate(all="ignore"):
        for name, (w, chunk_values) in cases.items():
            for bits, group in SELFTEST_WIDTHS:
                got = _digest(affine_quantize(w, bits, group, chunk_values=chunk_values))
                if chunk_values and got != _digest(affine_quantize(w, bits, group)):
                    got = "chunked output differs from unchunked"
                out[f"{name} {bits}/{group}"] = got
        pw, ps, pb = affine_quantize(cases["weights"][0], 4, 64)
    mod = "language_model.model.layers.0.mlp.down_proj"
    norm = f32_to_bf16(cases["weights"][0][0])
    tensors = [(mod + ".weight", "U32", pw.shape, pw.tobytes()), (mod + ".scales", "BF16", ps.shape, ps.tobytes()),
               (mod + ".biases", "BF16", pb.shape, pb.tobytes()),
               ("language_model.model.norm.weight", "BF16", norm.shape, norm.tobytes())]
    with tempfile.TemporaryDirectory() as d:
        write_st(os.path.join(d, "model-00001-of-00001.safetensors"), tensors)
        with open(os.path.join(d, "model-00001-of-00001.safetensors"), "rb") as fh:
            st = fh.read()
    q = {"group_size": 64, "bits": 4, "mode": "affine",
         "language_model.lm_head": {"group_size": 64, "bits": 6, "mode": "affine"}}
    cfg = {"architectures": ["Qwen3_5ForConditionalGeneration"], "model_type": "qwen3_5", "name": "Qw\u00e9n",
           "text_config": {"num_hidden_layers": 32, "rope_theta": 10000000.0, "rms_norm_eps": 1e-06,
                           "partial_rotary_factor": 0.25, "layer_types": ["linear_attention", "full_attention"]},
           "quantization": q, "quantization_config": q}
    index = {"metadata": {"total_size": len(st)}, "weight_map": dict(sorted((n, "model-00001-of-00001.safetensors")
                                                                          for n, *_ in tensors))}
    out["serialization"] = hashlib.sha256(st + json.dumps(cfg, indent=2).encode()
                                          + json.dumps(index, indent=2).encode()).hexdigest()
    return out


def _cpu_features():
    try:
        try:
            from numpy._core import _multiarray_umath as m
        except ImportError:
            from numpy.core import _multiarray_umath as m
        on = [f for f in m.__cpu_dispatch__ if m.__cpu_features__.get(f)]
        return f"SIMD baseline {' '.join(m.__cpu_baseline__) or '-'}, dispatch {' '.join(on) or '-'}"
    except Exception:  # noqa: BLE001
        return "SIMD features unknown"


def selftest(golden=None, out=print):
    """0 when this machine reproduces every recorded digest, else 1."""
    golden = SELFTEST_GOLDEN if golden is None else golden
    with open(__file__, "rb") as fh:
        me = hashlib.sha256(fh.read()).hexdigest()
    out(f"requant.py sha256 {me}; python {platform.python_version()} {platform.machine()}; numpy {np.__version__}; "
        f"{_cpu_features()}")
    got = selftest_digests()
    for k in sorted(set(got) | set(golden)):
        out(f"  {'ok  ' if golden.get(k) == got.get(k) else 'DIFF'} {k}: {str(got.get(k))[:16]}")
    if set(got) != set(golden) or any(golden[k] != got[k] for k in got):
        out("selftest FAILED: this machine does not reproduce the recorded bytes. Do not build or upload with it, and do "
            "not change the digests to pass: see docs/operations/model-revisions.md (Re-quantize and upload from CI).")
        return 1
    out(f"selftest ok: {len(got)} digests equal the recorded ones")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("verify", "build", "plan"):
        p = sub.add_parser(name)
        p.add_argument("--template", required=True)
        p.add_argument("--source", default="")
        p.add_argument("--recipe", default="g64")
        p.add_argument("--limit", type=int, default=6)
        p.add_argument("--out")
        p.add_argument("--shard-gb", type=float, default=5.0)
        p.add_argument("--base-group", type=int, default=None)
    st = sub.add_parser("selftest")
    st.add_argument("--record", action="store_true", help="print this machine's digests as JSON")
    a = ap.parse_args()
    if a.cmd == "selftest":
        if a.record:
            print(json.dumps(selftest_digests(), indent=2, sort_keys=True))
            return
        sys.exit(selftest())
    if a.base_group is None:
        a.base_group = 32 if a.recipe == "g32" else 64
    {"verify": cmd_verify, "build": cmd_build, "plan": cmd_plan}[a.cmd](a)


if __name__ == "__main__":
    main()
