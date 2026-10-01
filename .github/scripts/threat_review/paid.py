"""Reserve conservative cold-cache cost before transport; never retry paid calls."""
import json
from decimal import Decimal, ROUND_CEILING
from .client import request_json
from .context import SONNET, OPUS, ASTRA
from .state import BudgetStopped, USD

# USD per million tokens. Enforced again at the OpenRouter provider router.
# The 2x input reserve covers cache creation, including a one-hour cache write;
# caching discounts are never necessary for admission. Prompt size stays below
# long-context pricing tiers. No tools, images, search or per-request fees.
RATES = {SONNET: (2, 10), OPUS: (4, 20), ASTRA: (10, 50)}
OUTPUT_TOKENS = 4096


def microdollars(cost):
    if isinstance(cost, bool):
        raise ValueError("Invalid cost")
    value = Decimal(str(cost))
    if not value.is_finite() or value < 0:
        raise ValueError("Invalid cost")
    return int((value * USD).to_integral_value(rounding=ROUND_CEILING))


class PaidCalls:
    def __init__(self, state, pr, run, key, prefix, transport=request_json, alive=lambda: None):
        self.state, self.pr, self.run, self.key = state, pr, run, key
        self.prefix, self.transport, self.alive = prefix, transport, alive
        self.actual = self.reserved = self.cached_tokens = self.calls = 0
        self.unknown = 0
        self.stopped = None

    def __call__(self, url, key, payload):
        if self.stopped:
            raise BudgetStopped(self.stopped)
        self.alive()
        model = payload["model"]
        prompt_rate, output_rate = RATES[model]
        payload["max_tokens"] = OUTPUT_TOKENS
        payload["provider"] = {"require_parameters": True, "allow_fallbacks": False,
                               "max_price": {"prompt": prompt_rate, "completion": output_rate, "request": 0}}
        # Stable system + canonical index precedes the changing source payload.
        stable = payload["messages"][0]["content"] + "\n" + self.prefix
        block = {"type": "text", "text": stable}
        if model.startswith("anthropic/"):
            block["cache_control"] = {"type": "ephemeral"}
        payload["messages"][0]["content"] = [block]
        # UTF-8 bytes upper-bound ordinary BPE tokens; reserve ample additional
        # framing/schema overhead. Do not use a chars/4 estimate as a hard cap.
        upper_tokens = len(json.dumps(payload, ensure_ascii=False).encode()) + 4096
        if upper_tokens > 180_000:
            raise BudgetStopped("Request exceeds conservative context/price bound")
        reserve = upper_tokens * prompt_rate * 2 + OUTPUT_TOKENS * output_rate
        tier = "normal" if model == SONNET else "deep"
        ticket = self.state.reserve(self.pr, self.run, tier, reserve)
        self.reserved += reserve
        self.unknown += reserve
        self.calls += 1
        # An exception or cancellation after admission keeps the reservation.
        # Never blindly retry or assume an HTTP error means no provider charge.
        response = self.transport(url, self.key, payload)
        usage = response.get("usage", {})
        try:
            actual = microdollars(usage["cost"])
        except (KeyError, TypeError, ValueError, ArithmeticError):
            self.stopped = "Provider omitted valid cost accounting; reservation retained"
            return response  # save useful advice before stopping further spend
        try:
            self.state.settle(ticket, actual)
        except Exception:
            self.stopped = "Usage reconciliation failed; reservation retained"
            return response
        self.actual += actual
        self.unknown -= reserve
        details = usage.get("prompt_tokens_details")
        cached = details.get("cached_tokens", 0) if isinstance(details, dict) else 0
        if type(cached) is int and cached >= 0:
            self.cached_tokens += cached
        if actual > reserve:
            self.stopped = "Provider exceeded reserved cost; budget circuit breaker opened"
        return response

    def metrics(self):
        return {"actual_usd": self.actual / USD, "unreconciled_reserved_usd": self.unknown / USD,
                "requests": self.calls, "provider_cached_tokens": self.cached_tokens}
