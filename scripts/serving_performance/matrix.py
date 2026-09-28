"""The release matrix and raw measurement contract for a serving profile."""
import itertools
import math
import re

RUNTIME_REVISION = "cbv2-first-content-v1"
CHECKS = ("correctness", "constraints", "isolation", "cancellation", "accounting", "retirement")
MIN_SAMPLES = 20


def positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def widths(identity):
    return [1, 2, 4, 8, 12, 16] if "Ultra" in identity["chip_name"] else [1, 2, 4, 6, 8]


def identity_errors(identity):
    errors = []
    for field in ("id", "model_id", "provider_version", "chip_name"):
        if not isinstance(identity.get(field), str) or not identity[field].strip():
            errors.append(f"identity.{field} is required")
    if not digest(identity.get("artifact_sha256")):
        errors.append("identity.artifact_sha256 must identify verified model weights")
    if identity.get("runtime_revision") != RUNTIME_REVISION:
        errors.append("identity.runtime_revision does not match the serving policy")
    if identity.get("kv_backend") not in ("paged", "contiguous"):
        errors.append("identity.kv_backend must be the resolved backend")
    for field in ("gpu_cores", "memory_gb", "context_tokens_max"):
        if type(identity.get(field)) is not int or identity[field] <= 0:
            errors.append(f"identity.{field} must be a positive integer")
    return errors


def shapes(identity, serving_sets):
    """Include the configured context boundary as well as supported standard shapes."""
    context = identity["context_tokens_max"]
    outputs = [128, 1024, 4096]
    prompts = [1024, 4096, 16384, 32768]
    # Cover the full configured context even when it is below 32k. A profile
    # capped at 32k cannot be certified from only 16k + 4k workloads.
    prompts = sorted(set(prompts + [context - output for output in outputs if context > output]))
    return [
        (prompt, output, arrival, cache, tuple(sorted(models)))
        for prompt, output, arrival, cache, models in itertools.product(
            prompts, outputs, ("fixed", "staggered"), ("cold", "reused"), serving_sets
        ) if prompt + output <= context
    ]


def cell_key(cell):
    return (cell["width"], cell["prompt_tokens"], cell["output_tokens"],
            cell["arrival_pattern"], cell["cache_state"], tuple(sorted(cell["competing_models"])))
