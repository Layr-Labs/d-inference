"""Standalone SSD test-key selection/provenance; never performs key operations."""

from pathlib import Path
import string
import uuid


def parse_persistent_test_key_arguments(args, parser):
    identifiers, groups = args.persistent_test_namespace, args.persistent_test_access_group
    if identifiers is None and groups is None:
        return
    if (identifiers is None or groups is None or len(identifiers) != 1 or len(groups) != 1
            or args.cache_mode != "ssd" or args.key_mode != "persistent"):
        parser.error("persistent test keys require one UUID namespace and one access group, explicit SSD and persistent key modes")
    group = groups[0]
    allowed = string.ascii_letters + string.digits + ".-"
    if (len(group.encode("utf-8")) > 255 or len(group.split(".")) < 2
            or any(not part for part in group.split(".")) or any(c not in allowed for c in group)):
        parser.error("persistent test access group must be concrete and nonempty")
    try:
        args.persistent_test_namespace = str(uuid.UUID(identifiers[0]))
        args.persistent_test_access_group = group
        persistent_test_key_provenance(args)
    except (ValueError, OSError, RuntimeError) as error:
        parser.error("invalid persistent test namespace or root: " + str(error))


def persistent_test_key_provenance(args):
    if args.persistent_test_namespace is None:
        return None
    if args.cache_directory is not None:
        if (not Path(args.cache_directory).is_absolute()
                or args.cache_directory != args.cache_directory.strip()):
            raise ValueError("persistent test cache directory must be an absolute isolated path")
        root = Path(args.cache_directory).resolve()
    else:
        root = Path(args.output).resolve() / "prefix-cache"
    candidate = str(root).lower()
    protected = Path.home() / "Library/Caches/darkbloom"
    for name in ("kv3", "kv"):
        normal = str((protected / name).resolve()).lower()
        if (candidate == "/" or candidate == normal or candidate.startswith(normal + "/")
                or normal.startswith(candidate + "/")):
            raise ValueError("persistent test root overlaps the normal cache hierarchy")
    identifier = args.persistent_test_namespace
    stem = "io.darkbloom.test.ssd." + identifier
    return {"namespace": identifier, "access_group": args.persistent_test_access_group,
            "enclave_label": stem + ".enclave", "wrapped_kek_service": stem + ".kek",
            "wrapped_kek_account": "cache-" + identifier, "isolated_root": str(root),
            "requested_key_mode": "persistent"}


def validate_persistent_test_key_provenance(args, report):
    expected = persistent_test_key_provenance(args)
    if expected is None:
        return None
    observed = report.get("persistent_test_key_namespace")
    metrics = report.get("metrics_loaded", {})
    if (not isinstance(observed, dict) or any(observed.get(k) != v for k, v in expected.items())
            or "actual_key_mode" not in observed or "key_mode" not in metrics
            or observed["actual_key_mode"] != metrics["key_mode"]):
        raise RuntimeError("Persistent test key namespace provenance mismatch")
    if args.cache == "on" and metrics["key_mode"] != "persistent":
        raise RuntimeError("Requested persistent test key, observed " + repr(metrics["key_mode"]))
    return observed
