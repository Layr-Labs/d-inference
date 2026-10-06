"""Review narrow deadline evidence without granting universal serving policy."""
import hashlib
import json
import re

from .calibration import evaluate_calibration
from .check_receipts import check_errors
from .calibration_statistics import percentile
from .matrix import IDENTITY_FIELDS, digest, identity_errors, positive
from .posture import cooled_deadline_applicability
from .deadline_evidence import verify_deadline_samples

RUNTIME_FIELDS = ("configured_context_tokens", "effective_max_concurrency", "prefill_chunk_size",
                  "max_concurrent_partial_prefills", "solo_prefill_stripe_tokens", "mixed_prefill_token_cap")
BASE_FIELDS = set(IDENTITY_FIELDS) - {"context_tokens_max"}


def evaluate_deadline_profile(raw, *, evidence_root=None):
    receipt = json.loads(raw)
    result = {"qualified": False, "kind": "deadline_only", "receipt_sha256": hashlib.sha256(raw).hexdigest(),
              "errors": [], "profile": None}
    errors = result["errors"]
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1 or receipt.get("kind") != "deadline_only":
        errors.append("requires explicit deadline_only receipt version 1")
        return result
    applicability = receipt.get("applicability")
    if not cooled_deadline_applicability(applicability):
        errors.append("cooled evidence requires its exact whole-Mac quiescence, stable nominal and Automatic policy")
    identity = receipt.get("identity")
    if not isinstance(identity, dict):
        errors.append("exact deadline runtime identity is required")
        return result
    allowed = BASE_FIELDS | set(RUNTIME_FIELDS) | {"mtp"}
    if set(identity) - allowed:
        errors.append("deadline identity cannot attach universal concurrency/chunk policy or extra fields")
    common = {key: identity[key] for key in BASE_FIELDS | {"mtp"} if key in identity}
    common["context_tokens_max"] = identity.get("configured_context_tokens")
    errors.extend(identity_errors(common))
    for key, maximum in (("effective_max_concurrency", 16), ("prefill_chunk_size", 1_048_576)):
        if type(identity.get(key)) is not int or not 1 <= identity[key] <= maximum:
            errors.append(f"invalid actual {key}")
    if type(identity.get("max_concurrent_partial_prefills")) is not int or identity["max_concurrent_partial_prefills"] != 1:
        errors.append("calibrated atomic path requires actual serial partial prefill")
    stripe = identity.get("solo_prefill_stripe_tokens")
    if stripe is not None and (type(stripe) is not int or not 1 <= stripe <= 1_048_576):
        errors.append("invalid actual solo prefill stripe")
    cap = identity.get("mixed_prefill_token_cap")
    if cap is not None and (type(cap) is not int or cap not in (128, 256, 512)):
        errors.append("mixed cap must be the measured existing configuration")
    build = receipt.get("build", {})
    if not isinstance(build, dict):
        build = {}
    if (build.get("configuration") != "release" or build.get("dirty") is not False
            or build.get("debug_condition") is not False or build.get("debug_assertions_enabled") is not False
            or type(build.get("build_identity_version")) is not int or build["build_identity_version"] != 1):
        errors.append("qualification requires the clean release candidate without DEBUG")
    for key in ("source_commit", "sdk_commit"):
        if not isinstance(build.get(key), str) or re.fullmatch(r"[0-9a-f]{40}", build[key]) is None:
            errors.append(f"exact {key} is required")
    for key in ("source_tree_sha256", "test_binary_sha256", "metallib_sha256"):
        if not digest(build.get(key)):
            errors.append(f"verified {key} is required")
    errors.extend(check_errors(receipt.get("checks"), identity, build, evidence_root=evidence_root))
    try:
        verify_deadline_samples(receipt, evidence_root)
    except (OSError, ValueError, TypeError, KeyError, OverflowError) as error:
        errors.append(f"raw deadline evidence: {error}")
    if errors:
        return result
    calibration = evaluate_calibration(receipt.get("deadline_calibration"), result["receipt_sha256"],
                                       identity["configured_context_tokens"])
    result["calibration_evidence"] = calibration
    errors.extend(calibration["errors"])
    if not calibration["qualified"]:
        return result
    for index, cell in enumerate(receipt.get("deadline_calibration", {}).get("cells", [])):
        if cell.get("max_active_requests", 0) > identity["effective_max_concurrency"]:
            errors.append(f"cell {index}: work exceeds actual scheduler width")
        samples = cell.get("samples", [])
        rates = [sample.get("engine_decode_tps") for sample in samples]
        if not rates or any(not positive(rate) for rate in rates):
            errors.append(f"cell {index}: missing actual confirmed-token decode measurements")
        elif percentile(rates, .1) < 30:
            errors.append(f"cell {index}: measured decode p10 is below 30 TPS")
        if any(sample.get("thermal_state") != "nominal" or sample.get("power_mode") != "automatic"
               or sample.get("retired") is not True or sample.get("mtp") != identity.get("mtp")
               for sample in samples):
            errors.append(f"cell {index}: posture, retirement or actual MTP identity does not qualify")
    if not errors:
        result["qualified"] = True
        result["profile"] = {**identity, **applicability, "qualification_report_sha256": result["receipt_sha256"],
                             "deadline_calibration": calibration["calibration"]}
    return result
