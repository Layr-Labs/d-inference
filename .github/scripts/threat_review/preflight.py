"""Deployment readiness checks that never admit a PR or spend pilot budget."""
from decimal import Decimal, InvalidOperation
from .client import ReviewUnavailable, request_json


def amount(value):
    if isinstance(value, bool):
        raise ReviewUnavailable("Provider funding response is invalid")
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        raise ReviewUnavailable("Provider funding response is invalid") from None
    if not result.is_finite():
        raise ReviewUnavailable("Provider funding response is invalid")
    return result


def check_storage(state):
    ledger, sha = state.read("ledger.json")
    if not sha or not isinstance(ledger, dict) or ledger.get("version") != 1:
        raise ReviewUnavailable("Budget ledger is not initialized")
    if ledger.get("halted") is not False:
        raise ReviewUnavailable("Budget circuit breaker requires investigation")
    # A separate probe leaves every ledger reservation and pilot slot untouched.
    probe = {"state_writer": "verified", "paid_requests": 0}
    _, old_sha = state.read("preflight.json")
    result = state.write("preflight.json", probe, old_sha)
    commit = state.github.call(f"/commits/{result['commit']['sha']}")
    if not commit["commit"]["verification"]["verified"]:
        raise ReviewUnavailable("State writer commit signature is not verified")
    if state.read("preflight.json")[0] != probe:
        raise ReviewUnavailable("State writer read-back failed")


def check_funding(key, transport=request_json):
    if not key:
        raise ReviewUnavailable("OpenRouter key missing")
    info = transport("https://openrouter.ai/api/v1/key", key)["data"]
    limit = info["limit_remaining"]
    if limit is not None and amount(limit) <= 0:
        raise ReviewUnavailable("OpenRouter key spending limit is exhausted; restore funding before expecting reviews")
    credit = transport("https://openrouter.ai/api/v1/credits", key)["data"]
    if amount(credit["total_credits"]) - amount(credit["total_usage"]) <= 0:
        raise ReviewUnavailable("OpenRouter account has no remaining credits; restore funding before expecting reviews")


def check(state, key, transport=request_json):
    failures = []
    for name, verify in (("Storage", lambda: check_storage(state)),
                         ("Funding", lambda: check_funding(key, transport))):
        try:
            verify()
        except Exception as error:
            reason = str(error) if isinstance(error, ReviewUnavailable) else "invalid or unavailable response"
            failures.append(f"{name}: {reason}")
    if failures:
        raise ReviewUnavailable("; ".join(failures))
