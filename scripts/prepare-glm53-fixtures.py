#!/usr/bin/env python3
"""Pinned official Transformers CPU oracles with tiny synthetic weights, not model quality.

Commands deliberately separate metadata preparation from CPU execution:
  prepare --output NEW_DIR [--asset-source PINNED_ASSET_DIR]
  environment --output NEW_DIR
  generate --assets PREPARED_DIR --output NEW_DIR --resource-window APPROVAL
  canonicalize --oracle ORACLE_DIR --output NEW_DIR

Install Transformers from the exact git revision below in an isolated environment.
No from_pretrained model, remote model code, checkpoint weights, GPU or native Swift
implementation is used. The official implementation has no NextN/MTP oracle; these
fixtures must not be described as MTP qualification. Prompt fixtures remain separate
from the synthetic small-vocabulary numerical model.
"""
import argparse
from collections import Counter
import copy
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import struct
import sys
import urllib.request


SOURCE_REVISION = "f0705f991a71f05dad9569336b181119f5546f93"
MODEL_REVISION = "91b69215804f2d2036a8867f6ce44848e278dcda"
MODEL_REPOSITORY = "zai-org/GLM-5.3-Flash"
SOURCE_PREFIX = "src/transformers/models/glm5_next/"
SOURCE_HASHES = {
    "__init__.py": "5148b42fc4667082b87d9a7891e4cbbb066c5ac976f65ea8439147c41adef388",
    "configuration_glm5_next.py": "0a4df8f0238fd6e903fc94e7d89c0feee0bbea39bd8c92ccb42506e1b135d644",
    "modeling_glm5_next.py": "78e23c624010751f1578254145f313db2f3266579a0f9a396a3ff6cb5779f43d",
    "modular_glm5_next.py": "8a55fbaf21619374a75b8ef297be4f2a2a238f532d67791d7e02f355048e6a0d",
    "image_processing_glm5_next.py": "0771f6711d8b578a706297dd3445037a276e2c53eb001f6d4f2c69fea4be2d3f",
    "image_processing_pil_glm5_next.py": "c3065c32ece0cd46adf74a1aef5707da48a0596578503dabf47f874da0716663",
    "video_processing_glm5_next.py": "a90ece1916b8e6370626d6a114e942da371adece20bc0dea80e0595f46012261",
    "processing_glm5_next.py": "7d7b6573a251dd248c51080f89953cde387b3c2d53726e76beba612c3fe1297e",
}
ASSET_HASHES = {
    "config.json": "bb8f01c42cb92a52ca72e65afb4d5bd8d11aef083cd210e8de25dfb904f23e9f",
    "tokenizer.json": "19e773648cb4e65de8660ea6365e10acca112d42a854923df93db4a6f333a82d",
    "tokenizer_config.json": "98b1271574f41abf89427ae2dda030d94dc9478f0edc5a8bd240db213c6fd5fc",
    "chat_template.jinja": "0c4099f3382d6c92700dfb99725025360966fd73032f0ecf32377c0d9e6309c5",
    "processor_config.json": "aae38374c94b08cc9b0547c6e64f05b951bd9735cea571c6988f5ed552bed3ed",
    "generation_config.json": "230c30609ecbbb9e6583bedde8e7bdda0c6eb8fe5fad0eaeb3d1b293d751cb4f",
    "LICENSE": "30b85b6b9659f2e78aa259f8faf5d920a68dee7c9ced3fa6dba1f19f2bc4fca1",
}
PACKAGE_PINS = {
    "torch": "2.14.1", "torchvision": "0.29.1", "numpy": "2.5.4",
    "pillow": "12.3.0", "safetensors": "0.8.0",
}
DEFAULT_SEED = 0x474C4D53
MAX_ASSET_BYTES = 32 * 1024**2
MAX_ARCHIVE_BYTES = 64 * 1024**2
MAX_TENSORS = 12000
TOLERANCES = {
    "float32": {"atol": 3e-5, "rtol": 3e-5},
    "pixel_values": {"atol": 1e-6, "rtol": 1e-6},
    "integer_and_boolean": {"atol": 0, "rtol": 0},
    "topk": "Compare selected sets when order is unspecified; preserve raw CPU order too.",
    "scope": "Proposed native comparison tolerances; not measured full-model quality bounds.",
}
TEXT_OVERRIDES = {
    "vocab_size": 64, "hidden_size": 16, "intermediate_size": 32,
    "moe_intermediate_size": 24, "num_hidden_layers": 4,
    "num_attention_heads": 2, "num_key_value_heads": 2,
    "n_routed_experts": 4, "num_experts_per_tok": 2, "n_shared_experts": 1,
    "q_lora_rank": 8, "kv_lora_rank": 8, "qk_nope_head_dim": 8,
    "qk_rope_head_dim": 0, "qk_head_dim": 8, "v_head_dim": 8, "index_head_dim": 8,
    "index_n_heads": 2, "index_topk": 8, "index_kpool": 4,
    "max_position_embeddings": 256, "pad_token_id": 0, "eos_token_id": [1, 2],
    "layer_types": ["linear_attention"] * 3 + ["deepseek_sparse_attention"],
    "mlp_layer_types": ["dense"] * 3 + ["sparse"],
    "indexer_types": ["full"] * 4, "dtype": "float32", "num_nextn_predict_layers": 0,
    "linear_attn_config": {"num_heads": 2, "head_dim": 8,
                           "short_conv_kernel_size": 4, "gate_lower_bound": -5.0,
                           "kda_layers": [0, 1, 2], "full_attn_layers": [3]},
}
VISION_OVERRIDES = {
    "depth": 2, "hidden_size": 16, "num_heads": 2,
    "intermediate_size": 32, "out_hidden_size": 16,
    "projection_intermediate_size": 32,
}


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def open_directory(path):
    """Walk by descriptors: never follow an output/input parent symlink."""
    parts = Path(path).absolute().parts
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(parts[0], flags)
    try:
        for part in parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_regular(path, limit=MAX_ASSET_BYTES):
    path = Path(path).absolute()
    parent = open_directory(path.parent)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
        os.close(descriptor)
        raise ValueError(f"not a bounded regular file: {path}")
    with os.fdopen(descriptor, "rb") as source:
        data = source.read(limit + 1)
        after = os.fstat(source.fileno())
    if len(data) > limit or (before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError(f"file grew or changed during read: {path}")
    return data


class OutputDirectory:
    """Reserve a new owner-only directory; retain partial failures without overwrite."""
    def __init__(self, path):
        self.path = Path(path).absolute()
        parent = open_directory(self.path.parent)
        try:
            os.mkdir(self.path.name, mode=0o700, dir_fd=parent)
            self.descriptor = os.open(self.path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                      dir_fd=parent)
        finally:
            os.close(parent)

    def __enter__(self):
        return self

    def write(self, name, data):
        if Path(name).name != name or name in (".", ".."):
            raise ValueError("output members must be basenames")
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=self.descriptor)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)

    def __exit__(self, kind, error, traceback):
        try:
            if error is not None:
                self.write("failure.json", json_bytes({"complete": False, "error": str(error)}))
        finally:
            os.close(self.descriptor)


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if not newurl.startswith("https://"):
            raise ValueError("oracle assets require HTTPS redirects")
        return super().redirect_request(request, fp, code, message, headers, newurl)


def fetch_asset(name):
    # Closed metadata/tokenizer allowlist: a caller cannot request weights or code.
    if name not in ASSET_HASHES:
        raise ValueError("not an approved metadata asset")
    url = f"https://huggingface.co/{MODEL_REPOSITORY}/resolve/{MODEL_REVISION}/{name}"
    request = urllib.request.Request(url, headers={"User-Agent": "darkbloom-glm53-fixtures/1"})
    with urllib.request.build_opener(HTTPSRedirects()).open(request, timeout=60) as response:
        data = response.read(MAX_ASSET_BYTES + 1)
    if len(data) > MAX_ASSET_BYTES:
        raise ValueError("asset exceeds metadata byte bound")
    return data


def pinned_assets(directory):
    result = {}
    for name, expected in ASSET_HASHES.items():
        data = read_regular(Path(directory) / name)
        if digest(data) != expected:
            raise ValueError(f"pinned official asset changed: {name}")
        result[name] = data
    return result


def prepare(output, asset_source=None):
    with OutputDirectory(output) as target:
        for name, expected in ASSET_HASHES.items():
            data = read_regular(Path(asset_source) / name) if asset_source else fetch_asset(name)
            if digest(data) != expected:
                raise ValueError(f"pinned official asset changed: {name}")
            target.write(name, data)
        target.write("provenance.json", json_bytes({
            "schema_version": 1, "complete": True, "scope": "metadata-only; no model weights",
            "model_repository": MODEL_REPOSITORY, "model_revision": MODEL_REVISION,
            "asset_sha256": ASSET_HASHES, "transformers_revision": SOURCE_REVISION,
        }))


def environment_manifest():
    packages = {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()}
    for name, expected in PACKAGE_PINS.items():
        try:
            actual = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError as error:
            raise RuntimeError(f"missing oracle dependency: {name}=={expected}") from error
        if actual != expected:
            raise RuntimeError(f"oracle dependency mismatch: {name}={actual}, need {expected}")
    distribution = importlib.metadata.distribution("transformers")
    direct = json.loads(distribution.read_text("direct_url.json") or "{}")
    if (direct.get("url") != "https://github.com/huggingface/transformers.git"
            or direct.get("vcs_info", {}).get("commit_id") != SOURCE_REVISION):
        raise RuntimeError("Transformers must be installed from the exact official git commit")
    source_root = Path(distribution.locate_file("transformers/models/glm5_next"))
    for name, expected in SOURCE_HASHES.items():
        if digest(read_regular(source_root / name)) != expected:
            raise RuntimeError(f"installed official Transformers source changed: {name}")
    return {"python": sys.version, "platform": platform.platform(), "packages": packages,
            "transformers_direct_url": direct, "source_sha256": SOURCE_HASHES,
            "source_root": str(source_root), "device": "cpu", "dtype": "float32",
            "attention": "eager", "threads": 1, "hub_kernels": False}


def tiny_configuration(official):
    if official.get("model_type") != "glm5_next":
        raise ValueError("wrong official model type")
    result = copy.deepcopy(official)
    result.pop("quantization_config", None)
    result["text_config"].update(copy.deepcopy(TEXT_OVERRIDES))
    result["vision_config"].update(VISION_OVERRIDES)
    result.update(image_token_id=63, video_token_id=62, image_start_token_id=61,
                  image_end_token_id=60, video_start_token_id=59, video_end_token_id=58)
    return result


def transformers_configuration(native):
    """Constructor-only metadata; never pass this dialect to the native decoder."""
    result = copy.deepcopy(native)
    original_layers = result["text_config"]["layer_types"]
    hf_layers = ["indexed_attention" if value == "deepseek_sparse_attention" else value
                 for value in original_layers]
    result["text_config"]["layer_types"] = hf_layers
    rope = {"rope_type": "axial", "rope_theta": 10000.0}
    result["vision_config"]["rope_parameters"] = rope
    changes = [
        {"path": "text_config.layer_types", "native": original_layers, "transformers": hf_layers,
         "reason": "Pinned Transformers cache/forward dialect uses indexed_attention."},
        {"path": "vision_config.rope_parameters", "native": "absent", "transformers": rope,
         "reason": "Constructor-only axial RoPE metadata; not an official JSON/native schema field."},
    ]
    return result, changes


def fixed_parameter(torch, name, tensor, seed):
    """Integer-addressed values avoid ambient RNG/version-dependent initialization."""
    phase = int.from_bytes(hashlib.sha256(f"{seed}:{name}".encode()).digest()[:4], "little")
    values = ((torch.arange(tensor.numel(), dtype=torch.int64) * 17 + phase) % 257 - 128).float() / 512
    if "norm" in name and name.endswith("weight"):
        values = 1 + values / 10
    elif name.endswith("A_log") or name.endswith("dt_bias"):
        values = values - 2
    elif name.endswith(".scale"):
        values = 1 + values / 10
    return values.reshape(tensor.shape).to(dtype=tensor.dtype)


def set_fixed_weights(torch, model, seed):
    with torch.no_grad():
        for name, parameter in model.named_parameters():
            parameter.copy_(fixed_parameter(torch, name, parameter, seed))
        for name, buffer in model.named_buffers():
            # Rotary frequencies are model-defined, not random checkpoint weights.
            if name.endswith("e_score_correction_bias"):
                buffer.copy_(fixed_parameter(torch, name, buffer, seed))


class Trace:
    def __init__(self, torch):
        self.torch = torch
        self.tensors = {}
        self.calls = Counter()
        self.prefix = ""
        self.empty = []

    def add(self, name, value):
        if isinstance(value, self.torch.Tensor):
            if value.device.type != "cpu":
                raise RuntimeError("oracle produced non-CPU tensor")
            if value.numel() == 0:
                self.empty.append(name)
                return
            if value.is_floating_point() and not self.torch.isfinite(value).all().item():
                raise ValueError(f"non-finite oracle tensor: {name}")
            if name in self.tensors or len(self.tensors) >= MAX_TENSORS:
                raise ValueError(f"duplicate tensor name or tensor bound: {name}")
            self.tensors[name] = value.detach().contiguous().clone()
        elif isinstance(value, dict):
            for key, item in value.items():
                self.add(f"{name}.{key}", item)
        elif isinstance(value, (tuple, list)):
            for index, item in enumerate(value):
                self.add(f"{name}.{index}", item)

    def hook(self, name):
        def capture(module, args, kwargs, output):
            key = f"{self.prefix}.{name}"
            ordinal = self.calls[key]
            self.calls[key] += 1
            key += f".call{ordinal}"
            self.add(key + ".input", args)
            self.add(key + ".kwargs", kwargs)
            self.add(key + ".output", output)
        return capture

    def cache(self, name, cache):
        for index, layer in enumerate(cache.layers):
            for field in ("keys", "values", "conv_states", "recurrent_states", "indexer_keys"):
                self.add(f"{name}.layer{index}.{field}", getattr(layer, field, None))


def tensor_inventory(tensors):
    return {name: {"shape": list(value.shape), "dtype": str(value.dtype),
                   "elements": value.numel(), "sha256": digest(value.numpy().tobytes())}
            for name, value in sorted(tensors.items())}


def prompt_oracles(assets, tokenizer):
    tools = [{"type": "function", "function": {"name": "lookup", "description": "Fixed synthetic lookup",
              "parameters": {"type": "object", "properties": {"key": {"type": "string"}},
                             "required": ["key"]}}}]
    conversations = [
        ("text", [{"role": "user", "content": "Return the word violet."}], None),
        ("tools", [{"role": "user", "content": "Look up the string 007."},
                   {"role": "assistant", "content": "", "tool_calls": [
                       {"id": "fixture-call", "type": "function", "function": {
                           "name": "lookup", "arguments": {"key": "007"}}}]},
                   {"role": "tool", "tool_call_id": "fixture-call", "content": "violet"}], tools),
    ]
    result = []
    for name, messages, declared_tools in conversations:
        rendered = tokenizer.apply_chat_template(messages, tools=declared_tools, tokenize=False,
                                                  add_generation_prompt=True)
        tokens = tokenizer.encode(rendered, add_special_tokens=False)
        if not tokens:
            raise ValueError("official prompt oracle produced zero tokens")
        result.append({"name": name, "messages": messages, "tools": declared_tools,
                       "rendered": rendered, "token_ids": tokens})
    return {"scope": "official tokenizer/template only; separate from tiny numerical vocabulary",
            "template_sha256": digest(assets["chat_template.jinja"]), "cases": result}


def numeric_oracles(torch, reference, config, trace, seed):
    model = reference.Glm5NextForConditionalGeneration(config).cpu().float().eval()
    model.set_attn_implementation("eager")
    model.set_experts_implementation("eager")
    execution_backends = {"attention": {}, "experts": {}}
    for name, module in model.named_modules():
        if isinstance(module, (reference.Glm5NextTextAttention, reference.Glm5NextVisionAttention)):
            execution_backends["attention"][name] = module.config._attn_implementation
        if isinstance(module, reference.Glm5NextTextExperts):
            execution_backends["experts"][name] = module.config._experts_implementation
    if any(value != "eager" for group in execution_backends.values() for value in group.values()):
        raise RuntimeError("official attention and expert modules must both select eager execution")
    if not all(execution_backends.values()):
        raise RuntimeError("oracle did not construct both attention and expert modules")
    set_fixed_weights(torch, model, seed)
    weights = {name: value.detach().contiguous().clone() for name, value in model.state_dict().items()}
    handles = []
    for name, module in model.named_modules():
        if name and (any(True for _ in module.parameters(recurse=False))
                     or isinstance(module, (reference.Glm5NextTextDecoderLayer,
                                            reference.Glm5NextVisionBlock))):
            handles.append(module.register_forward_hook(trace.hook(name), with_kwargs=True))
    try:
        ids = torch.tensor([[(index * 13 + 7) % 57 + 1 for index in range(17)]], dtype=torch.int64)
        mask = torch.ones_like(ids, dtype=torch.bool)
        trace.prefix = "text.full"
        trace.add("text.input_ids", ids)
        full = model(input_ids=ids, attention_mask=mask, use_cache=True, return_dict=True)
        trace.add("text.full.logits", full.logits)
        trace.add("text.full.greedy_ids", full.logits.argmax(dim=-1))
        trace.cache("text.full.cache", full.past_key_values)
        cache = None
        steps = []
        for index in range(ids.shape[1]):
            trace.prefix = f"text.token{index}"
            result = model(input_ids=ids[:, index:index + 1], attention_mask=mask[:, :index + 1],
                           past_key_values=cache, use_cache=True, return_dict=True)
            cache = result.past_key_values
            steps.append(result.logits)
            trace.cache(f"text.token{index}.cache", cache)
        trace.add("text.tokenwise.logits", torch.cat(steps, dim=1))
        # Keep the observed discrepancy; do not silently replace one reference path.
        parity_error = (full.logits - torch.cat(steps, dim=1)).abs().max().item()
        trace.prefix = "text.left_padded"
        padded = torch.cat([torch.zeros((1, 2), dtype=torch.int64), ids], dim=1)
        padding_mask = torch.cat([torch.zeros((1, 2), dtype=torch.bool), mask], dim=1)
        trace.add("text.left_padded.input_ids", padded)
        trace.add("text.left_padded.attention_mask", padding_mask)
        trace.add("text.left_padded.logits", model(input_ids=padded, attention_mask=padding_mask,
                                                   use_cache=False, return_dict=True).logits)
        trace.prefix = "components.clipped_mlp"
        extreme = (torch.arange(32, dtype=torch.float32).reshape(2, 16) - 16) * 64
        trace.add("components.clipped_mlp.output", model.model.language_model.layers[0].mlp(extreme))
        trace.prefix = "components.hyperconnection"
        streams = torch.arange(384, dtype=torch.float32).reshape(2, 3, 4, 16) / 64 - 2
        trace.add("components.hyperconnection.result",
                  model.model.language_model.layers[0].attn_hc(streams))
        trace.prefix = "components.left_padded_indexer"
        hidden = fixed_parameter(torch, "indexer-input", torch.empty(2, 17, 16), seed)
        q_resid = fixed_parameter(torch, "indexer-q-residual", torch.empty(2, 17, 8), seed)
        valid = torch.ones(2, 17, dtype=torch.bool)
        valid[0, :2] = False
        indexer = model.model.language_model.layers[3].self_attn.indexer
        trace.add("components.left_padded_indexer.indices", indexer(hidden, q_resid, valid, None))
        trace.prefix = "components.kda_nonzero_state"
        shape = (2, 5, 2, 8)
        query, key, value = [fixed_parameter(torch, name, torch.empty(shape), seed)
                             for name in ("kda-q", "kda-k", "kda-v")]
        gate = fixed_parameter(torch, "kda-g", torch.empty(shape), seed) - 1
        beta = fixed_parameter(torch, "kda-beta", torch.empty(2, 5, 2), seed) + 0.5
        initial = fixed_parameter(torch, "kda-state", torch.empty(2, 2, 8, 8), seed)
        trace.add("components.kda_nonzero_state.inputs", {
            "query": query, "key": key, "value": value, "g": gate, "beta": beta, "initial_state": initial})
        for label, function in (("chunk", reference.chunk_kimi_delta_attention),
                                ("recurrent", reference.recurrent_kimi_delta_attention)):
            result = function(query, key, value, gate, beta, initial_state=initial.clone(),
                              output_final_state=True, use_qk_l2norm_in_kernel=True)
            trace.add(f"components.kda_nonzero_state.{label}", result)
        return model, weights, parity_error, execution_backends
    finally:
        for handle in handles:
            handle.remove()


def vision_oracles(torch, reference, model, trace):
    from transformers.models.glm5_next.image_processing_glm5_next import Glm5NextImageProcessor
    from transformers.models.glm5_next.video_processing_glm5_next import Glm5NextVideoProcessor
    from transformers.video_utils import VideoMetadata
    image_processor = Glm5NextImageProcessor(min_image_tokens=16, max_image_tokens=64)
    video_processor = Glm5NextVideoProcessor(min_image_tokens=16, max_image_tokens=128)
    image = (torch.arange(3 * 29 * 47).reshape(3, 29, 47) * 19 % 256).to(torch.uint8)
    trace.add("image.raw_chw", image)
    image_inputs = image_processor(images=image, return_tensors="pt")
    trace.add("image.processor", dict(image_inputs))
    handles = [module.register_forward_hook(trace.hook(name), with_kwargs=True)
               for name, module in model.named_modules() if name.startswith("model.visual")]
    handles.append(model.model.language_model.register_forward_hook(
        trace.hook("language_model.final"), with_kwargs=True))
    try:
        trace.prefix = "image"
        features = model.get_image_features(**image_inputs, return_dict=True)
        trace.add("image.features", features)
        count = sum(tensor.shape[0] for tensor in features.pooler_output)
        ids = torch.tensor([[3] + [63] * count + [4]], dtype=torch.int64)
        trace.add("image.input_ids", ids)
        trace.add("image.logits", model(input_ids=ids, **image_inputs, use_cache=False,
                                        return_dict=True).logits)
        video = torch.stack([image, image.roll(3, -1), image.roll(5, -2)])
        trace.add("video.raw_tchw", video)
        video_inputs = video_processor(videos=video, do_sample_frames=False, return_tensors="pt")
        trace.add("video.processor", dict(video_inputs))
        sample_metadata = VideoMetadata(total_num_frames=3, fps=2.0, duration=1.5)
        trace.add("video.sample_indices", torch.tensor(video_processor.sample_frames(sample_metadata)))
        trace.prefix = "video"
        video_features = model.get_video_features(**video_inputs, return_dict=True)
        trace.add("video.features", video_features)
        count = sum(tensor.shape[0] for tensor in video_features.pooler_output)
        ids = torch.tensor([[59] + [63] * count + [58]], dtype=torch.int64)
        trace.add("video.input_ids", ids)
        trace.add("video.logits", model(input_ids=ids, **video_inputs, use_cache=False,
                                        return_dict=True).logits)
        return {"image_features": len(features.pooler_output), "image_tokens": int(
            image_inputs["image_grid_thw"].prod(-1).sum().item() // 4),
            "video_tokens": count, "video_sampling": "explicit 3-frame synthetic input; sampling disabled"}
    finally:
        for handle in handles:
            handle.remove()


def generate(assets_directory, output, resource_window, seed=DEFAULT_SEED):
    if not resource_window or not resource_window.strip():
        raise ValueError("an explicit parent-approved CPU resource window is required")
    if not 0 <= seed < 2**32:
        raise ValueError("seed must be an unsigned 32-bit integer")
    assets = pinned_assets(assets_directory)
    environment = environment_manifest()
    with OutputDirectory(output) as target:
        # Must be set before importing the reference. No automatic remote kernels/downloads.
        os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false")
        import torch
        from safetensors.torch import save
        from transformers import AutoTokenizer
        from transformers.models.glm5_next import modeling_glm5_next as reference
        from transformers.models.glm5_next.configuration_glm5_next import Glm5NextConfig
        if digest(read_regular(reference.__file__)) != SOURCE_HASHES["modeling_glm5_next.py"]:
            raise RuntimeError("imported oracle differs from the verified distribution")
        torch.set_num_threads(1)
        torch.set_num_interop_threads(1)
        torch.use_deterministic_algorithms(True)
        torch.manual_seed(seed)
        native_config = tiny_configuration(json.loads(assets["config.json"]))
        config_dict, configuration_changes = transformers_configuration(native_config)
        target.write("native_configuration.json", json_bytes(native_config))
        target.write("transformers_configuration.json", json_bytes(config_dict))
        target.write("configuration-transforms.json", json_bytes(configuration_changes))
        target.write("environment.json", json_bytes(environment))
        config = Glm5NextConfig(**config_dict)
        trace = Trace(torch)
        with torch.inference_mode():
            model, weights, parity_error, execution_backends = numeric_oracles(torch, reference, config, trace, seed)
            media = vision_oracles(torch, reference, model, trace)
        tokenizer = AutoTokenizer.from_pretrained(str(Path(assets_directory).absolute()),
                                                  local_files_only=True, trust_remote_code=False)
        prompts = prompt_oracles(assets, tokenizer)
        if not weights or not trace.tensors:
            raise ValueError("zero-tensor oracle is not a fixture")
        artifacts = {}
        for name, tensors in (("weights.safetensors", weights), ("expected.safetensors", trace.tensors)):
            data = save(tensors, metadata={"scope": "synthetic-official-cpu-oracle-not-model-quality",
                                          "transformers_revision": SOURCE_REVISION})
            if len(data) > MAX_ARCHIVE_BYTES:
                raise ValueError("tiny oracle archive exceeded the size bound")
            target.write(name, data)
            artifacts[name] = {"sha256": digest(data), "bytes": len(data),
                               "tensor_count": len(tensors), "tensors": tensor_inventory(tensors)}
        target.write("prompts.json", json_bytes(prompts))
        target.write("manifest.json", json_bytes({
            "schema_version": 1, "complete": True, "synthetic": True,
            "scope": "tiny official target/vision equations and official tokenizer/template; NOT full-model quality or MTP",
            "source_revision": SOURCE_REVISION, "source_sha256": SOURCE_HASHES,
            "model_repository": MODEL_REPOSITORY, "model_revision": MODEL_REVISION,
            "official_asset_sha256": ASSET_HASHES, "seed": seed,
            "initializer": "sha256(seed:name), integer-addressed modulo-257 float32 values; see generator",
            "resource_window": resource_window, "device": "cpu", "threads": 1,
            "dtype": "float32", "attention": "eager", "tolerances": TOLERANCES,
            "observed_execution_backends": execution_backends,
            "sampling": "logits and greedy argmax only; no generated-language quality claim",
            "text_overrides": TEXT_OVERRIDES, "vision_overrides": VISION_OVERRIDES,
            "configuration_transforms": configuration_changes,
            "native_configuration_sha256": digest(json_bytes(native_config)),
            "transformers_configuration_sha256": digest(json_bytes(config_dict)),
            "weight_namespace": "unaltered Transformers state_dict; any native weight-name/layout mapping must be explicit",
            "num_nextn_predict_layers": 0,
            "empty_tensors_not_serialized": trace.empty,
            "reference_full_vs_tokenwise_max_abs": parity_error,
            "media": media, "artifacts": artifacts,
            "generator_sha256": digest(read_regular(__file__)),
            "environment_sha256": digest(json_bytes(environment)),
        }))


# Synthetic-fixture serialization only. No torch/model execution or real checkpoint conversion.
DTYPE_BYTES = {"F32": 4, "F64": 8, "I64": 8, "I32": 4, "U8": 1, "BOOL": 1}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def tensor_bytes(dtype, shape):
    if dtype not in DTYPE_BYTES or not isinstance(shape, list) or not shape or any(
            type(value) is not int or value <= 0 for value in shape):
        raise ValueError("unsupported synthetic tensor dtype/shape")
    size = math.prod(shape) * DTYPE_BYTES[dtype]
    if size > MAX_ARCHIVE_BYTES:
        raise ValueError("synthetic tensor exceeds archive bound")
    return size


def decode_safetensors(data):
    if not 8 < len(data) <= MAX_ARCHIVE_BYTES:
        raise ValueError("invalid bounded safetensors archive size")
    length = struct.unpack("<Q", data[:8])[0]
    if not 0 < length <= len(data) - 8:
        raise ValueError("invalid safetensors header length")
    header = json.loads(data[8:8 + length], object_pairs_hook=unique_object)
    payload = data[8 + length:]
    tensors, spans = {}, []
    for name, entry in header.items():
        if name == "__metadata__":
            continue
        if set(entry) != {"dtype", "shape", "data_offsets"}:
            raise ValueError("unexpected tensor header fields")
        size = tensor_bytes(entry["dtype"], entry["shape"])
        offsets = entry["data_offsets"]
        if (not isinstance(offsets, list) or len(offsets) != 2
                or any(type(value) is not int for value in offsets)
                or not 0 <= offsets[0] < offsets[1] <= len(payload)
                or offsets[1] - offsets[0] != size):
            raise ValueError(f"invalid tensor span: {name}")
        spans.append(tuple(offsets))
        tensors[name] = {"dtype": entry["dtype"], "shape": entry["shape"],
                         "data": payload[offsets[0]:offsets[1]]}
    position = 0
    for start, end in sorted(spans):
        if start != position:
            raise ValueError("tensor payload overlap or gap")
        position = end
    if position != len(payload) or not tensors or len(tensors) > MAX_TENSORS:
        raise ValueError("incomplete/empty tensor inventory")
    return tensors


def encode_safetensors(tensors):
    header = {"__metadata__": {"scope": "synthetic-fixture-only-bit-preserving-name-layout-mapping"}}
    payload = bytearray()
    for name, tensor in sorted(tensors.items()):
        size = tensor_bytes(tensor["dtype"], tensor["shape"])
        if size != len(tensor["data"]):
            raise ValueError(f"wrong payload size: {name}")
        start = len(payload)
        payload.extend(tensor["data"])
        header[name] = {"dtype": tensor["dtype"], "shape": tensor["shape"],
                        "data_offsets": [start, len(payload)]}
    encoded = json.dumps(header, sort_keys=True, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)
    data = struct.pack("<Q", len(encoded)) + encoded + payload
    if len(data) > MAX_ARCHIVE_BYTES:
        raise ValueError("canonical synthetic archive exceeds 64 MiB")
    return data


def native_fixture_schema(config):
    """Official split checkpoint geometry; matches native float32 inventory, not predictions."""
    c, v = config["text_config"], config["vision_config"]
    if (c["num_nextn_predict_layers"] != 0 or c["dtype"] != "float32"
            or c["num_hidden_layers"] != 4 or c["hidden_size"] != 16
            or c["vocab_size"] != 64 or v["depth"] != 2):
        raise ValueError("canonicalization accepts only this bounded synthetic target-only fixture")
    shapes = {}

    def add(name, *shape):
        if name in shapes:
            raise ValueError(f"duplicate schema name: {name}")
        shapes[name] = list(shape)

    def matrix(name, output, input):
        add(name + ".weight", output, input)

    def mlp(prefix, intermediate):
        for projection in ("gate_proj", "up_proj"):
            matrix(prefix + "." + projection, intermediate, c["hidden_size"])
        matrix(prefix + ".down_proj", c["hidden_size"], intermediate)

    h = c["hidden_size"]
    matrix("model.language_model.embed_tokens", c["vocab_size"], h)
    matrix("lm_head", c["vocab_size"], h)
    add("model.language_model.norm.weight", h)
    for layer, kind in enumerate(c["layer_types"]):
        prefix = f"model.language_model.layers.{layer}"
        add(prefix + ".input_layernorm.weight", h)
        add(prefix + ".post_attention_layernorm.weight", h)
        hc = c["hc_mult"]
        for site in ("attn", "ffn"):
            add(prefix + f".hc_{site}_fn", (2 + hc) * hc, hc * h)
            add(prefix + f".hc_{site}_base", (2 + hc) * hc)
            add(prefix + f".hc_{site}_scale", 3)
        attn = prefix + ".self_attn"
        if kind == "linear_attention":
            linear = c["linear_attn_config"]
            width = linear["num_heads"] * linear["head_dim"]
            for projection in ("q", "k", "v"):
                matrix(attn + f".{projection}_proj", width, h)
                add(attn + f".{projection}_conv1d.weight", width, 1, linear["short_conv_kernel_size"])
            for gate in ("f", "g"):
                matrix(attn + f".{gate}_a_proj", linear["head_dim"], h)
                matrix(attn + f".{gate}_b_proj", width, linear["head_dim"])
            matrix(attn + ".b_proj", linear["num_heads"], h)
            matrix(attn + ".o_proj", h, width)
            add(attn + ".A_log", linear["num_heads"])
            add(attn + ".dt_bias", width)
            add(attn + ".o_norm.weight", linear["head_dim"])
        elif kind == "deepseek_sparse_attention":
            matrix(attn + ".q_a_proj", c["q_lora_rank"], h)
            add(attn + ".q_a_layernorm.weight", c["q_lora_rank"])
            matrix(attn + ".q_b_proj", c["num_attention_heads"] * c["qk_head_dim"], c["q_lora_rank"])
            matrix(attn + ".kv_a_proj_with_mqa", c["kv_lora_rank"], h)
            add(attn + ".kv_a_layernorm.weight", c["kv_lora_rank"])
            matrix(attn + ".kv_b_proj", c["num_attention_heads"] * (c["qk_head_dim"] + c["v_head_dim"]),
                   c["kv_lora_rank"])
            matrix(attn + ".o_proj", h, c["num_attention_heads"] * c["v_head_dim"])
            indexer = attn + ".indexer"
            matrix(indexer + ".wq_b", c["index_n_heads"] * c["index_head_dim"], c["q_lora_rank"])
            matrix(indexer + ".wk", c["index_head_dim"], h)
            matrix(indexer + ".weights_proj", c["index_n_heads"], h)
            add(indexer + ".k_norm.weight", c["index_head_dim"])
            add(indexer + ".k_norm.bias", c["index_head_dim"])
            add(indexer + ".index_kpool_compress_ape", c["index_kpool"], c["index_head_dim"])
            add(indexer + ".index_kpool_compress_gate", c["index_head_dim"], h)
        else:
            raise ValueError("unknown synthetic layer kind")
        if c["mlp_layer_types"][layer] == "dense":
            mlp(prefix + ".mlp", c["intermediate_size"])
        else:
            matrix(prefix + ".mlp.gate", c["n_routed_experts"], h)
            add(prefix + ".mlp.gate.e_score_correction_bias", c["n_routed_experts"])
            mlp(prefix + ".mlp.shared_experts", c["moe_intermediate_size"] * c["n_shared_experts"])
            for expert in range(c["n_routed_experts"]):
                mlp(prefix + f".mlp.experts.{expert}", c["moe_intermediate_size"])
    prefix, vh = "model.visual", v["hidden_size"]
    add(prefix + ".patch_embed.proj.weight", vh, v["in_channels"], v["temporal_patch_size"],
        v["patch_size"], v["patch_size"])
    add(prefix + ".patch_embed.proj.bias", vh)
    add(prefix + ".post_layernorm.weight", vh)
    add(prefix + ".downsample.weight", v["out_hidden_size"], vh,
        v["spatial_merge_size"], v["spatial_merge_size"])
    add(prefix + ".downsample.bias", v["out_hidden_size"])
    for layer in range(v["depth"]):
        block = prefix + f".blocks.{layer}"
        for norm in ("norm1", "norm2"):
            add(block + f".{norm}.weight", vh)
        for norm in ("q_norm", "k_norm"):
            add(block + f".attn.{norm}.weight", vh // v["num_heads"])
        for name, out, inp in (("attn.qkv", 3 * vh, vh), ("attn.proj", vh, vh),
                               ("mlp.gate_proj", v["intermediate_size"], vh),
                               ("mlp.up_proj", v["intermediate_size"], vh),
                               ("mlp.down_proj", vh, v["intermediate_size"])):
            matrix(block + "." + name, out, inp)
            add(block + "." + name + ".bias", out)
    out = v["out_hidden_size"]
    for name, rows, columns in (("proj", out, out), ("gate_proj", v["projection_intermediate_size"], out),
                                ("up_proj", v["projection_intermediate_size"], out),
                                ("down_proj", out, v["projection_intermediate_size"])):
        matrix(prefix + ".merger." + name, rows, columns)
    for suffix in ("weight", "bias"):
        add(prefix + ".merger.post_projection_norm." + suffix, out)
    return shapes


def canonical_weight_mapping(tensors, config):
    schema = native_fixture_schema(config)
    result, operations = {}, []
    c = config["text_config"]
    width = c["linear_attn_config"]["num_heads"] * c["linear_attn_config"]["head_dim"]
    for name, tensor in sorted(tensors.items()):
        shape, raw = tensor["shape"], tensor["data"]
        if tensor["dtype"] != "F32" or tensor_bytes("F32", shape) != len(raw):
            raise ValueError("only complete F32 synthetic weights may be mapped")
        parts, operation = [], "identity"
        conv = re.fullmatch(r"(model\.language_model\.layers\.\d+\.self_attn)\.conv1d\.weight", name)
        experts = re.fullmatch(r"(model\.language_model\.layers\.\d+\.mlp\.experts)\.(gate_up_proj|down_proj)", name)
        if conv:
            k = c["linear_attn_config"]["short_conv_kernel_size"]
            if shape != [3 * width, 1, k]:
                raise ValueError("fused Q/K/V convolution shape mismatch")
            size = width * k * 4
            parts = [(conv[1] + f".{gate}_conv1d.weight", [width, 1, k], index * size, (index + 1) * size)
                     for index, gate in enumerate(("q", "k", "v"))]
            operation = "split-Q-K-V-axis0"
        elif experts:
            count, h, intermediate = c["n_routed_experts"], c["hidden_size"], c["moe_intermediate_size"]
            if experts[2] == "gate_up_proj":
                if shape != [count, 2 * intermediate, h]:
                    raise ValueError("stacked gate/up expert shape mismatch")
                size = intermediate * h * 4
                parts = [(experts[1] + f".{expert}.{gate}_proj.weight", [intermediate, h],
                          (expert * 2 + index) * size, (expert * 2 + index + 1) * size)
                         for expert in range(count) for index, gate in enumerate(("gate", "up"))]
                operation = "split-expert-axis0-then-gate-up-axis1"
            else:
                if shape != [count, h, intermediate]:
                    raise ValueError("stacked down expert shape mismatch")
                size = h * intermediate * 4
                parts = [(experts[1] + f".{expert}.down_proj.weight", [h, intermediate],
                          expert * size, (expert + 1) * size) for expert in range(count)]
                operation = "split-expert-axis0"
        else:
            destination = re.sub(r"\.(attn|ffn)_hc\.(fn|base|scale)$", r".hc_\1_\2", name)
            destination = destination.replace(".self_attn.forget_gate.", ".self_attn.")
            if destination != name:
                operation = "rename"
            parts = [(destination, shape, 0, len(raw))]
        destinations = []
        for destination, dimensions, start, end in parts:
            if destination in result:
                raise ValueError(f"duplicate canonical destination: {destination}")
            if schema.get(destination) != dimensions:
                raise ValueError(f"unexpected/malformed canonical tensor: {destination}")
            data = raw[start:end]
            result[destination] = {"dtype": "F32", "shape": dimensions, "data": data}
            destinations.append({"name": destination, "shape": dimensions, "dtype": "F32",
                                 "source_byte_range": [start, end], "sha256": digest(data)})
        reconstructed = b"".join(result[item["name"]]["data"] for item in destinations)
        if reconstructed != raw:
            raise ValueError(f"bitwise concatenation round trip failed: {name}")
        operations.append({"source": name, "shape": shape, "dtype": "F32", "sha256": digest(raw),
                           "operation": operation, "destinations": destinations,
                           "roundtrip": "concatenate destinations in listed order", "bitwise_equal": True})
    missing = sorted(set(schema) - set(result))
    if missing:
        raise ValueError(f"missing canonical tensor: {missing[0]}")
    return result, operations


def compact_case_index(names):
    names = set(names)

    def key(name):
        if name not in names:
            raise ValueError(f"missing expected oracle key: {name}")
        return name

    def state(prefix):
        return {"conv_states": [key(f"{prefix}.cache.layer{i}.conv_states.0") for i in range(3)],
                "kda_states": [key(f"{prefix}.cache.layer{i}.recurrent_states.0") for i in range(3)],
                "latent_kv": key(prefix + ".cache.layer3.keys"),
                "packed_indexer_keys_gates_validity": key(prefix + ".cache.layer3.indexer_keys")}

    def text_case(prefix, ids, logits, cached=False):
        result = {"input_ids": key(ids), "logits": key(logits),
                  "final_hidden": key(prefix + ".model.language_model.norm.call0.output"),
                  "layer_outputs": [key(prefix + f".model.language_model.layers.{i}.call0.output.0")
                                    for i in range(4)],
                  "dsa_indices": key(prefix + ".model.language_model.layers.3.self_attn.indexer.call0.output"),
                  "router": {"logits": key(prefix + ".model.language_model.layers.3.mlp.gate.call0.output.0"),
                             "weights": key(prefix + ".model.language_model.layers.3.mlp.gate.call0.output.1"),
                             "indices": key(prefix + ".model.language_model.layers.3.mlp.gate.call0.output.2")}}
        if cached:
            result["cache"] = state(prefix)
        return result

    cases = {"text_full": text_case("text.full", "text.input_ids", "text.full.logits", True),
             "text_left_padding": text_case("text.left_padded", "text.left_padded.input_ids",
                                            "text.left_padded.logits")}
    cases["text_full"]["attention_mask"] = "all true; same shape as input_ids"
    cases["text_left_padding"]["attention_mask"] = key("text.left_padded.attention_mask")
    cases["text_tokenwise"] = {"combined_logits": key("text.tokenwise.logits"), "steps": [
        text_case(f"text.token{i}", f"text.token{i}.model.language_model.embed_tokens.call0.input.0",
                  f"text.token{i}.lm_head.call0.output", True) for i in range(17)]}
    cases["text_tokenwise"]["attention_mask"] = "all true, length step_index + 1 including cached tokens"
    cases["kda_nonzero_state"] = {
        "inputs": {name: key("components.kda_nonzero_state.inputs." + name)
                   for name in ("query", "key", "value", "g", "beta", "initial_state")},
        "outputs": {kind: {"output": key(f"components.kda_nonzero_state.{kind}.0"),
                            "final_state": key(f"components.kda_nonzero_state.{kind}.1")}
                    for kind in ("chunk", "recurrent")}, "use_qk_l2norm_in_kernel": True}
    prefix = "components.left_padded_indexer.model.language_model.layers.3.self_attn.indexer"
    cases["dsa_left_padding"] = {"inputs": {name: key(prefix + f".call0.input.{index}")
        for index, name in enumerate(("hidden_states", "q_resid", "attention_mask"))},
        "indices": key("components.left_padded_indexer.indices"), "cache": None}
    for modality, raw, pixels, grid in (("image", "image.raw_chw", "pixel_values", "image_grid_thw"),
                                       ("video", "video.raw_tchw", "pixel_values_videos", "video_grid_thw")):
        cases[modality] = {"raw_pixels": key(raw), "input_ids": key(modality + ".input_ids"),
            "pixel_values": key(f"{modality}.processor.{pixels}"),
            "grid_thw": key(f"{modality}.processor.{grid}"),
            "vision_features": key(modality + ".features.pooler_output.0"),
            "downsampled_hidden": key(modality + ".features.last_hidden_state"),
            "final_hidden": key(modality + ".language_model.final.call0.output.last_hidden_state"),
            "logits": key(modality + ".logits"),
            "vision_block_outputs": [key(f"{modality}.model.visual.blocks.{i}.call0.output") for i in range(2)]}
    cases["video"]["sample_indices"] = key("video.sample_indices")
    return {"schema_version": 1, "weights": "native-weights.safetensors",
            "configuration": "native_configuration.json", "expected": "expected.safetensors",
            "tolerances": TOLERANCES, "cases": cases,
            "notes": ["Cache conv layout is [B,3*H*D,K]; recurrent state is [B,H,Dk,Dv].",
                      "Indexer state concatenates key, pool gate and validity channels.",
                      "KDA/DSA outputs are official CPU reference observations, not native predictions.",
                      "Text/tool render and token expectations are separate in prompts.json."]}


def canonicalize(oracle, output):
    oracle = Path(oracle)
    original_manifest = read_regular(oracle / "manifest.json")
    manifest = json.loads(original_manifest)
    if (manifest.get("synthetic") is not True or manifest.get("complete") is not True
            or manifest.get("source_revision") != SOURCE_REVISION
            or manifest.get("model_revision") != MODEL_REVISION
            or manifest.get("num_nextn_predict_layers") != 0):
        raise ValueError("canonicalization requires the complete pinned synthetic target-only oracle")
    native_data = read_regular(oracle / "native_configuration.json")
    if digest(native_data) != manifest["native_configuration_sha256"]:
        raise ValueError("native fixture configuration digest changed")
    config = json.loads(native_data)
    archives = {}
    for name in ("weights.safetensors", "expected.safetensors"):
        data = read_regular(oracle / name, MAX_ARCHIVE_BYTES)
        if digest(data) != manifest["artifacts"][name]["sha256"]:
            raise ValueError(f"original oracle archive changed: {name}")
        archives[name] = data
    original = decode_safetensors(archives["weights.safetensors"])
    mapped, operations = canonical_weight_mapping(original, config)
    expected = decode_safetensors(archives["expected.safetensors"])
    index = compact_case_index(expected)
    native_weights = encode_safetensors(mapped)
    if decode_safetensors(native_weights) != mapped:
        raise ValueError("canonical archive serialization was not bit preserving")
    mapping = {"schema_version": 1, "synthetic_fixture_only": True, "numerical_operations": [],
               "source_archive_sha256": digest(archives["weights.safetensors"]),
               "destination_archive_sha256": digest(native_weights),
               "source_tensor_count": len(original), "destination_tensor_count": len(mapped),
               "source_payload_bytes": sum(len(t["data"]) for t in original.values()),
               "destination_payload_bytes": sum(len(t["data"]) for t in mapped.values()),
               "all_roundtrips_bitwise_equal": True, "operations": operations}
    schema_path = Path(__file__).resolve().parent.parent / (
        "libs/mlx-swift-lm/Libraries/MLXLLM/Models/GLM5NextWeightInventory.swift")
    mapping["native_schema_reference"] = {"path": str(schema_path), "sha256": digest(read_regular(schema_path)),
        "symbol": "GLM5NextWeightInventory.schema(configuration:storage:)",
        "scope": "float32 inventory metadata only; Swift was not executed as an oracle"}
    with OutputDirectory(output) as target:
        for name, data in archives.items():
            target.write(name, data)  # exact copies, never a new reference forward
        for name in ("native_configuration.json", "transformers_configuration.json", "configuration-transforms.json",
                     "environment.json", "prompts.json"):
            target.write(name, read_regular(oracle / name))
        target.write("reference-manifest.json", original_manifest)
        target.write("native-weights.safetensors", native_weights)
        target.write("weight-mapping.json", json_bytes(mapping))
        target.write("case-index.json", json_bytes(index))
        updated = copy.deepcopy(manifest)
        updated.update(reference_manifest_sha256=digest(original_manifest),
                       canonicalizer_sha256=digest(read_regular(__file__)),
                       weight_namespace="canonical official split names in native-weights.safetensors; original weights retained",
                       canonicalization={"mapping": "weight-mapping.json", "case_index": "case-index.json",
                                         "bit_preserving": True, "synthetic_only": True})
        updated["artifacts"]["native-weights.safetensors"] = {"sha256": digest(native_weights),
            "bytes": len(native_weights), "tensor_count": len(mapped), "tensors": {
                name: {"shape": tensor["shape"], "dtype": tensor["dtype"],
                       "elements": math.prod(tensor["shape"]), "sha256": digest(tensor["data"])}
                for name, tensor in sorted(mapped.items())}}
        updated["weight_mapping_sha256"] = digest(json_bytes(mapping))
        updated["case_index_sha256"] = digest(json_bytes(index))
        target.write("manifest.json", json_bytes(updated))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("prepare", help="download/copy hash-pinned metadata, never weights")
    setup.add_argument("--output", type=Path, required=True)
    setup.add_argument("--asset-source", type=Path)
    env = commands.add_parser("environment", help="validate installed pins without model execution")
    env.add_argument("--output", type=Path, required=True)
    run = commands.add_parser("generate", help="execute tiny official CPU oracle in an approved window")
    run.add_argument("--assets", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--resource-window", required=True)
    run.add_argument("--seed", type=int, default=DEFAULT_SEED)
    conversion = commands.add_parser("canonicalize", help="bit-preserving synthetic fixture names/layout only")
    conversion.add_argument("--oracle", type=Path, required=True)
    conversion.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.output, args.asset_source)
    elif args.command == "environment":
        with OutputDirectory(args.output) as output:
            output.write("environment.json", json_bytes(environment_manifest()))
    elif args.command == "generate":
        generate(args.assets, args.output, args.resource_window, args.seed)
    else:
        canonicalize(args.oracle, args.output)
    print(args.output.absolute())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, importlib.metadata.PackageNotFoundError) as error:
        raise SystemExit(f"GLM53 fixture preparation failed: {error}") from error
