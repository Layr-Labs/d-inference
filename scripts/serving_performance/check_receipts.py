"""Verify scoped prerequisite files, never a caller's passing flag/hash alone."""
import hashlib
import json
from pathlib import Path
import re

from .build_identity import verified_build_identity
from .matrix import CHECKS, digest, positive

SDK_SCOPES = frozenset(("constraints", "isolation"))
SDK_PASSED_MARKERS = {
    "constraints": ('Suite "CBv2 row-local token constraints" passed',),
    "isolation": ('Test "finished request id reuse rebuilds fresh constraint state" passed',
                  'Test "auxiliary accounting includes hidden/token history and isolates requests" passed'),
}
LIVE_SCOPES = frozenset(CHECKS) - SDK_SCOPES
RUNTIME_FIELDS = ("configured_context_tokens", "effective_max_concurrency", "prefill_chunk_size",
                  "max_concurrent_partial_prefills", "solo_prefill_stripe_tokens", "mixed_prefill_token_cap")
MAX_RECEIPT_BYTES = 8 * 1024 * 1024


def _load(reference, path_key, hash_key, evidence_root, cache, *, as_text=False):
    path = reference.get(path_key)
    expected = reference.get(hash_key)
    if not isinstance(path, str) or not path or not digest(expected):
        raise ValueError(f"requires actual {path_key} and valid {hash_key}")
    if evidence_root is None:
        raise ValueError("an explicit evidence root is required to verify raw prerequisite files")
    root = Path(evidence_root).resolve(strict=True)
    actual = (root / path).resolve(strict=True)
    if not actual.is_relative_to(root) or not actual.is_file():
        raise ValueError("prerequisite receipt must be a file within the evidence root")
    key = (actual, expected, as_text)
    if key not in cache:
        with actual.open("rb") as stream:
            raw = stream.read(MAX_RECEIPT_BYTES + 1)
        if len(raw) > MAX_RECEIPT_BYTES or hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError(f"{path_key} content does not match its reviewed hash")
        value = raw.decode("utf-8") if as_text else json.loads(raw)
        if not as_text and not isinstance(value, dict):
            raise ValueError("prerequisite receipt must contain an object")
        cache[key] = value
    return cache[key]


def _sdk_check(raw, check, build, evidence_root, cache):
    if check not in SDK_SCOPES or raw.get("kind") != "deterministic_regression":
        raise ValueError("SDK unit evidence is limited to constraints/isolation")
    scopes = raw.get("scopes")
    if (type(raw.get("schema_version")) is not int or raw["schema_version"] != 1
            or not isinstance(scopes, list) or not scopes or not all(scope in SDK_SCOPES for scope in scopes)
            or check not in scopes):
        raise ValueError("SDK evidence must declare its narrow verified scopes")
    sdk = build.get("sdk_commit")
    if not isinstance(sdk, str) or re.fullmatch(r"[0-9a-f]{40}", sdk) is None or raw.get("sdk_commit") != sdk:
        raise ValueError("SDK prerequisite revision differs from the candidate")
    counts = [raw.get("xctest_passed", 0), raw.get("swift_testing_passed", 0)]
    if (type(raw.get("exit_code")) is not int or raw["exit_code"] != 0
            or any(type(count) is not int or count < 0 for count in counts) or sum(counts) == 0
            or not digest(raw.get("log_sha256"))):
        raise ValueError("SDK prerequisite must record successful actual tests and a log digest")
    log = _load(raw, "log_path", "log_sha256", evidence_root, cache, as_text=True)
    for scope in scopes:
        for marker in SDK_PASSED_MARKERS[scope]:
            if re.search(r"(?m)^[ \t]*✔[ \t]+" + re.escape(marker) + r"(?: after [0-9.]+ seconds)?\.$", log) is None:
                raise ValueError(f"SDK log has no actual passing marker for {scope}: {marker}")
    if counts[0] and re.search(r"(?m)^[ \t]*Executed " + str(counts[0]) + r" tests?, with 0 failures\b", log) is None:
        raise ValueError("SDK log does not confirm the declared passing XCTest count")
    if counts[1] and re.search(r"(?m)^[ \t]*✔ Test run with " + str(counts[1])
            + r" tests?(?: in [0-9]+ suites?)? passed\b", log) is None:
        raise ValueError("SDK log does not confirm the declared passing Swift Testing count")


def _live_check(raw, provenance, check, identity, build):
    if check not in LIVE_SCOPES or raw.get("kind") != "serving_lifecycle" or (type(raw.get("schemaVersion")) is not int or raw["schemaVersion"] != 1):
        raise ValueError("live prerequisite requires an explicit serving_lifecycle receipt")
    expected = {"modelID": identity.get("model_id"), "artifactSHA256": identity.get("artifact_sha256"),
                "providerVersion": identity.get("provider_version"), "runtimeRevision": identity.get("runtime_revision"),
                "actualKVBackend": identity.get("kv_backend")}
    if any(not isinstance(value, str) or not value or raw.get(key) != value for key, value in expected.items()):
        raise ValueError("live prerequisite model/artifact/provider/runtime differs from the candidate")
    if raw.get("mtp") != identity.get("mtp"):
        raise ValueError("live prerequisite MTP identity differs from the candidate")
    runtime = raw.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("live prerequisite requires actual factory configuration")
    for field in RUNTIME_FIELDS:
        expected_value = identity.get(field)
        present = field in identity
        if field == "configured_context_tokens" and "context_tokens_max" in identity:
            expected_value, present = identity["context_tokens_max"], True
        if present and runtime.get(field) != expected_value:
            raise ValueError(f"live prerequisite {field} differs from the candidate")
    source = provenance.get("source")
    if not isinstance(source, dict):
        raise ValueError("live prerequisite requires actual source provenance")
    for source_key, candidate_key, pattern in (
            ("head", "source_commit", r"[0-9a-f]{40}"),
            ("dependency_head", "sdk_commit", r"[0-9a-f]{40}"),
            ("source_tree_sha256", "source_tree_sha256", r"[0-9a-f]{64}")):
        value = build.get(candidate_key)
        if not isinstance(value, str) or re.fullmatch(pattern, value) is None or source.get(source_key) != value:
            raise ValueError(f"live prerequisite {candidate_key} differs from the candidate")
    if (source.get("dirty") is not False or type(provenance.get("return_code")) is not int
            or provenance["return_code"] != 0 or any(provenance.get(key) is not True for key in
                ("artifact_unchanged", "source_unchanged", "binary_unchanged"))
            or provenance.get("foreign_work_before") or provenance.get("foreign_work_during")):
        raise ValueError("live prerequisite execution was unsuccessful, dirty, changed or not exclusive")
    actual_build = verified_build_identity(raw, provenance)
    if actual_build["binarySHA256"] != build.get("test_binary_sha256"):
        raise ValueError("live prerequisite binary differs from the candidate")
    metallibs = provenance.get("metallibs_sha256")
    if not digest(build.get("metallib_sha256")) or not isinstance(metallibs, dict) or set(metallibs.values()) != {build["metallib_sha256"]}:
        raise ValueError("live prerequisite metallib differs from the candidate")
    records = raw.get("checks")
    expected_phases = {"prefill", "after_mtp_content" if identity.get("mtp") is not None else "after_content"}
    if (raw.get("passed") is not True or not isinstance(records, list) or len(records) != len(expected_phases)
            or any(not isinstance(record, dict) for record in records)
            or {record.get("phase") for record in records} != expected_phases):
        raise ValueError("live prerequisite must retain every required real lifecycle phase")
    for record in records:
        if (record.get("reached") is not True or record.get("cancelled") is not True
                or record.get("retired") is not True or record.get("followupParity") is not True
                or not positive(record.get("serviceFractionAtCancel")) or record["serviceFractionAtCancel"] > 1):
            raise ValueError("live lifecycle phases did not pass actual cancellation/retirement/parity")
        confirmed, accounted, generations = (record.get(key) for key in
                                             ("confirmedTokens", "generatedTokensAccounted", "generationRetirements"))
        if (any(type(value) is not int for value in (confirmed, accounted, generations))
                or confirmed < 0 or accounted != confirmed or generations != 1
                or (record["phase"] != "prefill" and confirmed == 0)):
            raise ValueError("live lifecycle work was not accounted exactly once")


def check_errors(checks, identity, build, *, evidence_root=None, cache=None):
    errors, cache = [], {} if cache is None else cache
    build = build if isinstance(build, dict) else {}
    for check in CHECKS:
        try:
            reference = checks.get(check) if isinstance(checks, dict) else None
            if not isinstance(reference, dict):
                raise ValueError("missing raw prerequisite reference")
            raw = _load(reference, "receipt_path", "receipt_sha256", evidence_root, cache)
            if check in SDK_SCOPES:
                _sdk_check(raw, check, build, evidence_root, cache)
            else:
                provenance = _load(reference, "provenance_path", "provenance_sha256", evidence_root, cache)
                _live_check(raw, provenance, check, identity, build)
        except (OSError, ValueError, TypeError, KeyError, OverflowError) as error:
            errors.append(f"{check}: {error}")
    return errors
