#!/usr/bin/env python3
"""Create bounded synthetic MiMo control-flow fixtures offline, never model evidence."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct


def configuration(asymmetric):
    value = {
        "model_type": "mimo_v2", "architectures": ["MiMoV2ForCausalLM"],
        "hidden_size": 64, "intermediate_size": 64, "moe_intermediate_size": 64,
        "vocab_size": 128, "num_hidden_layers": 2,
        "max_position_embeddings": 1024 if asymmetric else 128,
        "sliding_window_size": 8, "sliding_window": 8, "num_nextn_predict_layers": 3,
        "hybrid_layer_pattern": [0, 1], "moe_layer_freq": [0, 1],
        "partial_rotary_factor": 0.5, "attention_value_scale": 1,
        "layernorm_epsilon": 0.000001, "attention_projection_layout": "fused_qkv",
        "moe_router_dtype": "bfloat16", "hidden_act": "silu", "dtype": "bfloat16",
        "attention_bias": False, "tie_word_embeddings": False, "attention_dropout": 0,
        "scoring_func": "sigmoid", "topk_method": "noaux_tc", "n_routed_experts": 4,
        "num_experts_per_tok": 2, "n_group": 1, "topk_group": 1,
        "norm_topk_prob": True, "n_shared_experts": None, "routed_scaling_factor": None,
        "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 64 if asymmetric else 32,
        "v_head_dim": 128 if asymmetric else 32, "swa_num_attention_heads": 2,
        "swa_num_key_value_heads": 1, "swa_head_dim": 64 if asymmetric else 32,
        "swa_v_head_dim": 128 if asymmetric else 32,
        "rope_theta": 10000000, "swa_rope_theta": 10000,
        "add_full_attention_sink_bias": False, "add_swa_attention_sink_bias": True,
        "eos_token_id": 1, "pad_token_id": 0,
        "vision_config": {
            "depth": 2, "hidden_size": 8, "intermediate_size": 16,
            "num_heads": 2, "num_key_value_heads": 1, "num_query_groups": 2,
            "out_hidden_size": 64, "patch_size": 2, "spatial_patch_size": 2,
            "temporal_patch_size": 2, "spatial_merge_size": 2,
            "fullatt_block_indexes": [0], "vit_window_attn_types": [-1, 0],
            "use_sink": True, "hidden_act": "silu", "window_size": 8,
            "visual_token_window_size": 8, "in_channels": 3, "qk_channels": 4, "kv_channels": 4,
        },
        "audio_config": {
            "audio_channels": 20, "audio_segment_size": 4, "group_size": 4,
            "input_local_dim": 8, "input_local_attn_heads": 2, "input_local_head_dim": 4,
            "input_local_layers": 2, "out_hidden_size": 64, "speech_vocab_size": "16",
            "speech_zeroemb_idx": "0", "add_post_norm": True, "input_full_attention": True,
            "input_local_intermediate_size": 16, "projection_layers": 2,
            "rope_theta": 10000, "input_local_hidden_dropout": 0, "partial_rotary_factor": 1,
        },
        "processor_config": {
            "patch_size": 2, "merge_size": 2, "temporal_patch_size": 2,
            "rope_type": "rope", "temporal_compression_ratio": 1,
            "use_video_timestamps": True, "use_per_grid_t_timestamps": False,
            "image_min_pixels": 16, "image_max_pixels": 256,
            "video_min_pixels": 16, "video_max_pixels": 256, "video_total_max_pixels": 512,
            "audio_channels": 20, "audio_group_size": 4, "audio_segment_size": 4,
            "audio_zeroemb_idx": [0] * 20, "audio_sampling_rate": 24000, "audio_n_mels": 80,
        },
        "omlx_mimo_mtp": {"architecture": "mimo_v2_nextn", "storage": "embedded",
                          "num_layers": 3, "file": "model-mtp.safetensors"},
        "quantization": {"mode": "mxfp4", "bits": 4, "group_size": 32},
    }
    for key, token in {"image_token_id": 2, "video_token_id": 3, "vision_start_token_id": 4,
                       "vision_end_token_id": 5, "audio_token_id": 6,
                       "audio_start_token_id": 7, "audio_end_token_id": 8}.items():
        value[key] = value["processor_config"][key] = token
    return value


def tensors(config):
    # Mirrors the pinned SDK's strict ConvertedLoadPlan and vision/audio inventories.
    result = {}

    def add(key, shape, dtype="BF16", file="target.safetensors"):
        result[key] = {"shape": shape, "dtype": dtype, "file": file}

    add("model.embed_tokens.weight", [128, 64])
    add("model.norm.weight", [64])
    add("lm_head.weight", [128, 64])
    value_width = config["v_head_dim"]
    head_width = config["head_dim"]
    for layer in range(2):
        prefix = f"model.layers.{layer}."
        for norm in ("input_layernorm", "post_attention_layernorm"):
            add(prefix + norm + ".weight", [64])
        for name, width in (("q_proj", 2 * head_width), ("k_proj", head_width), ("v_proj", value_width)):
            add(prefix + "self_attn." + name + ".weight", [width, 64])
        add(prefix + "self_attn.o_proj.weight", [64, 2 * value_width])
        if layer == 0:
            for name in ("gate_proj", "up_proj", "down_proj"):
                add(prefix + "mlp." + name + ".weight", [64, 64])
        else:
            add(prefix + "self_attn.attention_sink_bias", [2])
            add(prefix + "mlp.gate.weight", [4, 64])
            add(prefix + "mlp.gate.e_score_correction_bias", [4], "F32")
            for name in ("gate_proj", "up_proj", "down_proj"):
                add(prefix + "mlp.switch_mlp." + name + ".weight", [4, 64, 8], "U32")
                add(prefix + "mlp.switch_mlp." + name + ".scales", [4, 64, 2], "U8")
    vision = {"visual.patch_embed.proj.weight": [8, 3, 2, 2, 2],
              "visual.merger.ln_q.weight": [8], "visual.merger.mlp.0.weight": [32, 32],
              "visual.merger.mlp.2.weight": [64, 32]}
    for layer in range(2):
        prefix = f"visual.blocks.{layer}."
        for norm in ("norm1", "norm2"):
            vision[prefix + norm + ".weight"] = [8]
        for name, rows, cols in (("attn.qkv", 16, 8), ("attn.proj", 8, 8),
                                 ("mlp.gate_proj", 16, 8), ("mlp.up_proj", 16, 8),
                                 ("mlp.down_proj", 8, 16)):
            vision[prefix + name + ".weight"] = [rows, cols]
            vision[prefix + name + ".bias"] = [rows]
        if layer == 1:
            vision[prefix + "attn.sinks"] = [2]
    for key, shape in vision.items():
        add(key, shape, file="vision.safetensors")
    audio = {f"speech_embeddings.{channel}.weight": [16, 8] for channel in range(20)}
    for layer in range(2):
        prefix = f"audio_encoder.input_local_transformer.layers.{layer}."
        for norm in ("input_layernorm", "post_attention_layernorm"):
            audio[prefix + norm + ".weight"] = [8]
        for name in ("q_proj", "k_proj", "v_proj"):
            audio[prefix + "self_attn." + name + ".weight"] = [8, 8]
            audio[prefix + "self_attn." + name + ".bias"] = [8]
        audio[prefix + "self_attn.o_proj.weight"] = [8, 8]
        for name in ("gate_proj", "up_proj"):
            audio[prefix + "mlp." + name + ".weight"] = [16, 8]
        audio[prefix + "mlp.down_proj.weight"] = [8, 16]
    audio.update({"audio_encoder.input_local_transformer.norm.weight": [8],
                  "audio_encoder.projection.mlp.0.weight": [128, 32],
                  "audio_encoder.projection.mlp.2.weight": [64, 128]})
    for key, shape in audio.items():
        add(key, shape, file="audioPatch.safetensors")
    for layer in range(3):
        prefix = f"mtp.layers.{layer}."
        for norm in ("enorm", "hnorm", "input_layernorm", "pre_mlp_layernorm", "final_layernorm"):
            add(prefix + norm + ".weight", [64], file="model-mtp.safetensors")
        add(prefix + "self_attn.attention_sink_bias", [2], file="model-mtp.safetensors")
        for name, rows, cols in (("eh_proj", 64, 128), ("self_attn.q_proj", 2 * head_width, 64),
                                 ("self_attn.k_proj", head_width, 64), ("self_attn.v_proj", value_width, 64),
                                 ("self_attn.o_proj", 64, 2 * value_width), ("mlp.gate_proj", 64, 64),
                                 ("mlp.up_proj", 64, 64), ("mlp.down_proj", 64, 64)):
            module = prefix + name
            config["quantization"][module] = {"mode": "affine", "bits": 4, "group_size": 64}
            add(module + ".weight", [rows, cols // 8], "U32", "model-mtp.safetensors")
            for suffix in ("scales", "biases"):
                add(module + "." + suffix, [rows, cols // 64], file="model-mtp.safetensors")
    return result


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def prepare(output, asymmetric=False):
    if output.exists() or output.is_symlink():
        raise FileExistsError("fixture output already exists")
    config = configuration(asymmetric)
    inventory = tensors(config)
    if len(inventory) != 193:
        raise ValueError("synthetic tensor inventory changed")
    root = output / "tiny-bf16"
    root.mkdir(parents=True, mode=0o700)
    total = 0
    for name in sorted({entry["file"] for entry in inventory.values()}):
        header, payload = {"__metadata__": {"fixture": "synthetic-ci-not-model-evidence"}}, bytearray()
        for key, entry in sorted(inventory.items()):
            if entry["file"] != name:
                continue
            count, dtype = math.prod(entry["shape"]), entry["dtype"]
            if dtype == "U32":
                data = struct.pack("<I", 0x22222222) * count
            elif dtype == "U8":
                data = bytes([127]) * count
            else:
                values = [((index % 13) + 1) / 100 for index in range(count)]
                if dtype == "BF16":
                    words = [struct.unpack("<I", struct.pack("<f", value))[0] for value in values]
                    data = b"".join(struct.pack("<H", (word + 0x7FFF + ((word >> 16) & 1)) >> 16)
                                    for word in words)
                else:
                    data = struct.pack("<" + "f" * count, *values)
            start = len(payload)
            payload.extend(data)
            header[key] = {"shape": entry["shape"], "dtype": dtype,
                           "data_offsets": [start, len(payload)]}
        encoded = json_bytes(header).rstrip(b"\n")
        encoded += b" " * (-len(encoded) % 8)
        if 8 + len(encoded) + len(payload) >= 1 << 20:
            raise ValueError("synthetic shard exceeds fixture bound")
        (root / name).write_bytes(struct.pack("<Q", len(encoded)) + encoded + payload)
        total += len(payload)
    config_data = json_bytes(config)
    (root / "config.json").write_bytes(config_data)
    (root / "model.safetensors.index.json").write_bytes(json_bytes({
        "metadata": {"total_size": total}, "weight_map": {key: entry["file"] for key, entry in inventory.items()}}))
    template = "<|im_start|>x<think>{% if enable_thinking is false %}</think>{% endif %}"
    vocab = {"<unk>": 0, "<|im_end|>": 1, "<|im_start|>": 9, "<think>": 10,
             "</think>": 11, "x": 12, "<stop>": 13}
    (root / "tokenizer.json").write_bytes(json_bytes({
        "version": "1.0", "truncation": None, "padding": None,
        "added_tokens": [{"id": token, "content": spelling, "single_word": False,
                          "lstrip": False, "rstrip": False, "normalized": False, "special": True}
                         for spelling, token in vocab.items() if spelling != "x"],
        "normalizer": None, "pre_tokenizer": {"type": "Whitespace"}, "post_processor": None,
        "decoder": {"type": "ByteLevel"}, "model": {"type": "BPE", "vocab": vocab, "merges": [],
            "unk_token": "<unk>", "byte_fallback": False, "fuse_unk": False}}))
    (root / "tokenizer_config.json").write_bytes(json_bytes({"tokenizer_class": "PreTrainedTokenizerFast",
        "eos_token": "<|im_end|>", "unk_token": "<unk>", "chat_template": template}))
    (root / "chat_template.jinja").write_text(template, encoding="utf-8")
    manifest = {"source_repository": "XiaomiMiMo/MiMo-V2.6-Flash-RL", "source_revision": "a" * 40,
                "source_config_sha256": hashlib.sha256(config_data).hexdigest(),
                "experts": "original E2M1/E8M0 codes, group 32, no requantization",
                "dense": "FP8 dequantized to BF16; original BF16 unchanged",
                "output_tensor_count": len(inventory), "output_weight_bytes": total,
                "modality_tensor_counts": {prefix: sum(key.startswith(prefix + ".") for key in inventory)
                                           for prefix in ("visual", "audio_encoder", "speech_embeddings")},
                "mtp_embedded": config["omlx_mimo_mtp"]}
    manifest_data = json_bytes(manifest)
    (root / "conversion_manifest.json").write_bytes(manifest_data)
    (output / "provenance.json").write_bytes(json_bytes({
        "artifactID": "synthetic-provider-ci", "sourceRepository": manifest["source_repository"],
        "sourceRevision": manifest["source_revision"],
        "conversionManifestSHA256": hashlib.sha256(manifest_data).hexdigest()}))
    return output.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--asymmetric", action="store_true")
    parser.add_argument("--github-env", type=Path)
    args = parser.parse_args()
    path = prepare(args.output, args.asymmetric)
    lines = [f"MIMO_V26_SERIAL_LOAD_FIXTURES={path}",
             f"MIMO_V26_WIRED_METADATA_FIXTURE={path / 'tiny-bf16'}"]
    if any("\n" in line or "\r" in line for line in lines):
        raise ValueError("invalid environment path")
    if args.github_env:
        with args.github_env.open("a", encoding="utf-8") as destination:
            destination.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
