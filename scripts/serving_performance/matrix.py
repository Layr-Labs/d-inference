"""The release matrix and raw measurement contract for a serving profile."""
import itertools
import math
import re

RUNTIME_REVISION = "cbv2-first-content-v2"
CHECKS = ("correctness", "constraints", "isolation", "cancellation", "accounting", "retirement")
MIN_SAMPLES = 20
IDENTITY_FIELDS = (
    "id", "model_id", "artifact_sha256", "provider_version", "runtime_revision",
    "kv_backend", "chip_name", "gpu_cores", "memory_gb", "context_tokens_max",
)


def positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def widths(identity):
    return [1, 2, 4, 8, 12, 16] if "Ultra" in identity["chip_name"] else [1, 2, 4, 6, 8]


def identity_errors(identity):
    errors = [f"identity.{field} is not a supported identity field"
              for field in sorted(identity.keys() - set(IDENTITY_FIELDS) - {"mtp"})]
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
    mtp = identity.get("mtp")
    if mtp is not None:
        errors.extend(mtp_errors(mtp))
    return errors


def mtp_errors(mtp):
    if not isinstance(mtp, dict):
        return ["identity.mtp must describe the actual active assistant"]
    fields = {"enabled", "artifact_sha256", "max_draft_tokens", "fixed_draft_tokens",
              "max_speculative_batch", "verification_mode", "max_automatic_rectangular_tokens"}
    if (set(mtp) - fields or fields - {"fixed_draft_tokens"} - set(mtp)
            or mtp.get("enabled") is not True or not digest(mtp.get("artifact_sha256"))):
        return ["identity.mtp requires the exact verified active configuration"]
    errors = []
    for field in ("max_draft_tokens", "max_speculative_batch", "max_automatic_rectangular_tokens"):
        if type(mtp.get(field)) is not int or mtp[field] < 0:
            errors.append(f"identity.mtp.{field} must be nonnegative")
    fixed = mtp.get("fixed_draft_tokens")
    if fixed is not None and (type(fixed) is not int or fixed < 0):
        errors.append("identity.mtp.fixed_draft_tokens must be null or nonnegative")
    if not errors and (mtp["max_draft_tokens"] > 7 or not 1 <= mtp["max_speculative_batch"] <= 8
                       or (fixed is not None and fixed > mtp["max_draft_tokens"])):
        errors.append("identity.mtp exceeds runtime configuration bounds")
    if mtp.get("verification_mode") not in ("serial_target", "rectangular", "rectangular_exact", "automatic"):
        errors.append("identity.mtp.verification_mode is unsupported")
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
