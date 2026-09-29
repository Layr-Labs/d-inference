"""Verify compile-time facts emitted by the actual running test image."""
from .matrix import digest


def verified_build_identity(report, provenance, *, require_release=True):
    actual = report.get("buildIdentity")
    if (not isinstance(actual, dict) or type(actual.get("version")) is not int or actual["version"] != 1
            or type(actual.get("debugCompilationCondition")) is not bool
            or type(actual.get("debugAssertionsEnabled")) is not bool
            or not digest(actual.get("binarySHA256"))):
        raise ValueError("executing test image must report actual compile-time build identity")
    binaries = provenance.get("test_binaries_sha256")
    if not isinstance(binaries, dict) or actual["binarySHA256"] not in binaries.values():
        raise ValueError("reported build identity does not match a supervised test image")
    if require_release and (provenance.get("build_configuration") != "release"
            or actual["debugCompilationCondition"] or actual["debugAssertionsEnabled"]):
        raise ValueError("qualification requires a release image without DEBUG or debug assertions")
    return actual
