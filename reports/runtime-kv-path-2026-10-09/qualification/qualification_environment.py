"""The explicit environment contract for qualification subprocesses."""
import hashlib
import json

SYSTEM_ENVIRONMENT_KEYS = frozenset((
    "HOME", "PATH", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
    "USER", "LOGNAME", "SHELL", "__CF_USER_TEXT_ENCODING",
))


def child_environment(ambient):
    return {key: value for key, value in ambient.items() if key in SYSTEM_ENVIRONMENT_KEYS}


def environment_identity(environment):
    encoded = json.dumps(environment, sort_keys=True, separators=(",", ":")).encode()
    return {"policy": "system_allowlist_v1", "values": environment,
            "SHA256": hashlib.sha256(encoded).hexdigest()}


def validate_environment(identity):
    values = identity.get("values")
    if (not isinstance(values, dict) or any(not isinstance(value, str) for value in values.values())
            or child_environment(values) != values or environment_identity(values) != identity):
        raise RuntimeError("Invalid qualification child environment contract")
