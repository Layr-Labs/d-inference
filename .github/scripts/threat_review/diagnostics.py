"""Content-free failure metadata safe for the public report and Actions artifacts."""
import hashlib
import json
import re
import sys
from pathlib import Path

from .client import APIError, ReviewUnavailable, ScanTimeout
from .state import BudgetStopped


class ReviewFailure(ReviewUnavailable):
    def __init__(self, message, code, **details):
        super().__init__(message)
        self.diagnostic = {"code": code, **details}


def response_metadata(text):
    raw = text.encode("utf-8", errors="replace")
    first = text.lstrip()
    prefix = ("empty" if not first else "fence" if first.startswith("```") else
              "object" if first.startswith("{") else "array" if first.startswith("[") else "other")
    return {"response_bytes": len(raw), "response_sha256": hashlib.sha256(raw).hexdigest(),
            "response_prefix": prefix}


def request_id(response):
    metadata = response.get("ResponseMetadata") if isinstance(response, dict) else None
    value = metadata.get("RequestId") if isinstance(metadata, dict) else None
    # Do not reflect arbitrary provider strings into public logs.
    return value if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F-]{36}", value) else None


def parse_object(text):
    if not isinstance(text, str):
        raise ReviewFailure("Model returned a non-text response", "RESPONSE_TEXT_MISSING")
    metadata = response_metadata(text)
    try:
        result = json.loads(text)
    except json.JSONDecodeError as error:
        # JSONDecodeError.msg may contain provider-supplied property names.
        category = {
            "Extra data": "extra_data",
            "Expecting value": "expected_value",
            "Expecting property name enclosed in double quotes": "expected_property",
            "Expecting ',' delimiter": "expected_comma",
            "Expecting ':' delimiter": "expected_colon",
        }.get(error.msg, "invalid_syntax")
        raise ReviewFailure("Model returned invalid JSON", "RESPONSE_JSON_INVALID",
                            line=error.lineno, column=error.colno, offset=error.pos,
                            json_error=category,
                            **metadata) from None
    except (ValueError, RecursionError):
        # Interpreter limits can reject excessive integers or nesting before
        # the ordinary schema validator runs. Never publish exception text.
        raise ReviewFailure("Model JSON exceeds parser limits", "RESPONSE_JSON_LIMIT",
                            **metadata) from None
    if not isinstance(result, dict):
        raise ReviewFailure("Model returned a non-object response", "RESPONSE_OBJECT_REQUIRED", **metadata)
    return result


def failure_record(error, active_request):
    detail = getattr(error, "diagnostic", None)
    if detail is None:
        # Unknown exception messages may contain credentials, prompts or source.
        detail = {"code": "REVIEW_FAILED"}
        if isinstance(error, APIError):
            detail = {"code": "HTTP_ERROR", "http_status": error.status}
        elif isinstance(error, ScanTimeout):
            detail = {"code": "SCAN_TIMEOUT"}
        elif isinstance(error, BudgetStopped):
            detail = {"code": "REVIEW_BUDGET_STOPPED"}
    return {**active_request, **detail}


def write_diagnostics(env, snapshot):
    """Separate content-free artifact; never upload the full findings report."""
    if env.get("THREAT_REVIEW_DIAGNOSTICS_FILE"):
        value = {key: snapshot.get(key) for key in (
            "covered_units", "total_units", "integration_completed", "depth_batches_pending",
            "active_request", "diagnostics", "response_repairs")}
        # The scanner revision and canonical threat-model revision can differ.
        # Record only validated SHA identifiers, never arbitrary environment text.
        value["revisions"] = {key: env[name] for key, name in (
            ("scanner", "THREAT_REVIEW_SCANNER_SHA"), ("threat_model", "THREAT_REVIEW_BASE_SHA"))
            if re.fullmatch(r"[0-9a-f]{40}", env.get(name, ""))}
        path = Path(env["THREAT_REVIEW_DIAGNOSTICS_FILE"])
        temporary = path.with_name(path.name + ".tmp")
        try:
            temporary.write_text(json.dumps(value, indent=2))
            temporary.replace(path)
        except OSError:
            # Diagnostics must not prevent the saved findings/summary/gate from
            # being produced. Never print filesystem paths or exception text.
            print("DIAGNOSTICS_WRITE_FAILED: local diagnostics unavailable", file=sys.stderr)
            return False
    return True
