"""Closed artifact geometry, not a native executable capability."""
import math

PREFIX = "language_model.model."
LAYERS = ["sliding_attention"] * 5 + ["full_attention"]
LAYERS *= 5
DTYPE_BYTES = {"BF16": 2, "U32": 4}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_geometry(root):
    require(root["model_type"] == "gemma4", "wrong root model")
    text = root["text_config"]
    expected = {
        "model_type": "gemma4_text", "num_hidden_layers": 30,
        "hidden_size": 2816, "intermediate_size": 2112,
        "num_attention_heads": 16, "num_key_value_heads": 8,
        "head_dim": 256, "global_head_dim": 512,
        "num_global_key_value_heads": 2, "sliding_window": 1024,
        "num_kv_shared_layers": 0, "attention_k_eq_v": True,
        "enable_moe_block": True, "num_experts": 128, "top_k_experts": 8,
        "moe_intermediate_size": 704, "use_double_wide_mlp": False,
        "hidden_size_per_layer_input": 0, "vocab_size": 262144,
        "tie_word_embeddings": True, "use_bidirectional_attention": "vision",
        "dtype": "bfloat16", "attention_bias": False,
        "hidden_activation": "gelu_pytorch_tanh", "final_logit_softcapping": 30.0,
        "max_position_embeddings": 262144, "layer_types": LAYERS,
    }
    for key, value in expected.items():
        require(type(text[key]) is type(value) and text[key] == value,
                "unsupported geometry: " + key)
    require(root["tie_word_embeddings"] is True, "untied root")
    require(text["rope_parameters"] == {
        "sliding_attention": {"rope_type": "default", "rope_theta": 10000.0},
        "full_attention": {"rope_type": "proportional", "rope_theta": 1000000.0,
                           "partial_rotary_factor": 0.25}}, "unsupported rotary policy")
    expected_quantization = {"bits": 4, "group_size": 64, "mode": "affine"}
    for layer in range(30):
        for module in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"]:
            expected_quantization[PREFIX + f"layers.{layer}." + module] = {
                "bits": 8, "group_size": 64}
    require(root["quantization"] == expected_quantization,
            "quantization defaults/120 overrides differ")
    require(root["quantization_config"] == expected_quantization,
            "quantization containers disagree")
    return text


def expected_text_tensors():
    """Derive packed shapes from logical module widths, not header examples."""
    result = {}

    def tensor(name, dtype, shape):
        require(name not in result, "duplicate expected tensor")
        result[name] = {"dtype": dtype, "shape": shape,
                        "bytes": math.prod(shape) * DTYPE_BYTES[dtype]}

    def quantized(module, logical_shape, bits=4):
        width = logical_shape[-1]
        require(width % 64 == 0, "unaligned input")
        tensor(module + ".weight", "U32", logical_shape[:-1] + [width // (32 // bits)])
        for suffix in ["scales", "biases"]:
            tensor(module + "." + suffix, "BF16", logical_shape[:-1] + [width // 64])

    quantized(PREFIX + "embed_tokens", [262144, 2816])
    tensor(PREFIX + "norm.weight", "BF16", [2816])
    for index, kind in enumerate(LAYERS):
        base = PREFIX + f"layers.{index}."
        for name in ["input_layernorm", "post_attention_layernorm",
                     "pre_feedforward_layernorm", "post_feedforward_layernorm",
                     "post_feedforward_layernorm_1", "pre_feedforward_layernorm_2",
                     "post_feedforward_layernorm_2"]:
            tensor(base + name + ".weight", "BF16", [2816])
        tensor(base + "layer_scalar", "BF16", [1])
        tensor(base + "router.scale", "BF16", [2816])
        tensor(base + "router.per_expert_scale", "BF16", [128])
        quantized(base + "router.proj", [128, 2816], 8)
        for name, output, input_width in [
                ("gate_proj", 2112, 2816), ("up_proj", 2112, 2816),
                ("down_proj", 2816, 2112)]:
            quantized(base + "mlp." + name, [output, input_width], 8)
        for name, output, input_width in [
                ("gate_proj", 704, 2816), ("up_proj", 704, 2816),
                ("down_proj", 2816, 704)]:
            quantized(base + "experts.switch_glu." + name, [128, output, input_width])
        sliding = kind == "sliding_attention"
        head, kv = (256, 8) if sliding else (512, 2)
        for name, output, input_width in [
                ("q_proj", 16 * head, 2816), ("k_proj", kv * head, 2816),
                ("o_proj", 2816, 16 * head)]:
            quantized(base + "self_attn." + name, [output, input_width])
        if sliding:
            quantized(base + "self_attn.v_proj", [kv * head, 2816])
        for name in ["q_norm", "k_norm"]:
            tensor(base + "self_attn." + name + ".weight", "BF16", [head])
    return result


def state_geometry(cut, prompt, chunk, output, scalar_bytes=2):
    """Logical KV only; BF16 expectation is not native dtype attestation."""
    require(type(cut) is int and 1 <= cut < 30, "invalid cut")
    require(all(type(x) is int and x > 0 for x in [prompt, chunk, output]),
            "invalid request")
    require(prompt <= 8192 and chunk <= min(prompt, 512) and output <= 128,
            "outside private planning envelope")
    require(scalar_bytes in (2, 4), "unsupported scalar planning size")
    capacity, frontier = prompt + output, prompt + output - 1
    layers = []
    for index, kind in enumerate(LAYERS):
        sliding = kind == "sliding_attention"
        head, kv = (256, 8) if sliding else (512, 2)
        retained = min(frontier, 1024) if sliding else frontier
        slots = 1024 if sliding else capacity
        width = kv * head * scalar_bytes * 2
        layers.append({
            "globalLayerIndex": index, "rank": int(index >= cut),
            "localLayerIndex": index if index < cut else index - cut,
            "attention": kind, "queryHeads": 16, "kvHeads": kv, "headDim": head,
            "sharesKVWithLayer": None, "absoluteFrontier": frontier,
            "retainedStart": frontier - retained, "retainedTokens": retained,
            "keyShape": [1, kv, retained, head], "valueShape": [1, kv, retained, head],
            "maximumStorageSlots": slots, "logicalCapacityBytes": slots * width,
            "logicalRetainedKVBytes": retained * width,
            "maximumChunkAttentionViewTokens": 1023 + chunk if sliding else capacity,
            "namedStateEntries": 3,
        })
    return {
        "scope": "metadata_only_not_admission", "promptTokens": prompt,
        "chunkTokens": chunk, "maximumOutputTokens": output,
        "capacityTokens": capacity, "completeLengthFrontier": frontier,
        "earlyEOSFrontierRule": "promptTokens + committedOutputTokens - 1",
        "KVScalarBytesAssumption": scalar_bytes, "nativeKVDTypeVerified": False,
        "recurrentLayers": [], "recurrentBytes": 0, "layers": layers,
        "rankLogicalKVCapacityBytes": [sum(x["logicalCapacityBytes"] for x in layers
                                            if x["rank"] == rank) for rank in range(2)],
        "rankNamedStateEntries": [3 * cut, 3 * (30 - cut)],
        "namedStateEntries": 90,
        "unaccountedForAdmission": ["allocator rounding", "attention chunk views",
            "MoE routing/sort/selected-expert workspace", "dense projection scratch",
            "quantized materialization and read overlap", "boundary/transport buffers",
            "logits and sampler", "diagnostic copies", "asynchronous evaluation retention"],
    }
