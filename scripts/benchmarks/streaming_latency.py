"""Client-clock measurements for a single OpenAI-compatible text stream.

SSE fragments are not token counts. TTFT includes content or reasoning text;
role-only frames, keepalives and usage frames do not start that clock.
"""

import json
import math


def strict_json(raw):
    def constant(value):
        raise ValueError("Nonfinite JSON number")
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result
    def floating(raw_value):
        value = float(raw_value)
        if not math.isfinite(value):
            raise ValueError("Nonfinite JSON number")
        return value
    return json.loads(raw, parse_constant=constant, parse_float=floating, object_pairs_hook=pairs)


class StreamObservation:
    def __init__(self):
        self.first_token_ns = self.first_content_ns = self.first_reasoning_ns = None
        self.last_token_ns = None
        self.usage = None
        self.finish_reason = None
        self.done = False
        self.text_events = 0
        self.event_count = 0

    def accept(self, payload, elapsed_ns):
        if self.done:
            raise ValueError("Data after [DONE]")
        self.event_count += 1
        if payload == "[DONE]":
            self.done = True
            return
        event = strict_json(payload)
        if not isinstance(event, dict) or event.get("error") is not None:
            raise ValueError("Invalid/error SSE event; inspect retained response")
        if event.get("usage") is not None:
            usage = event["usage"]
            if not isinstance(usage, dict) or any(
                type(usage.get(k)) is not int or usage[k] < 0
                for k in ("prompt_tokens", "completion_tokens")
            ):
                raise ValueError("Invalid reported token usage")
            if self.usage is not None and self.usage != usage:
                raise ValueError("Conflicting terminal usage")
            self.usage = usage
        choices = event.get("choices", [])
        if not isinstance(choices, list) or len(choices) > 1:
            raise ValueError("Expected one text completion")
        for choice in choices:
            if choice.get("index", 0) != 0:
                raise ValueError("Unexpected completion index")
            delta = choice.get("delta", {})
            if not isinstance(delta, dict) or delta.get("tool_calls") or delta.get("function_call"):
                raise ValueError("This benchmark admits text completions only")
            content = delta.get("content") or ""
            reasoning = delta.get("reasoning_content", delta.get("reasoning")) or ""
            if not isinstance(content, str) or not isinstance(reasoning, str):
                raise ValueError("Nontext completion delta")
            if content and self.first_content_ns is None:
                self.first_content_ns = elapsed_ns
            if reasoning and self.first_reasoning_ns is None:
                self.first_reasoning_ns = elapsed_ns
            if content or reasoning:
                if self.finish_reason is not None:
                    raise ValueError("Text after terminal choice")
                self.first_token_ns = elapsed_ns if self.first_token_ns is None else self.first_token_ns
                self.last_token_ns = elapsed_ns
                self.text_events += 1
            finish = choice.get("finish_reason")
            if finish is not None:
                if self.finish_reason is not None or finish not in ("stop", "length", "content_filter"):
                    raise ValueError("Duplicate/invalid terminal choice")
                self.finish_reason = finish

    def summary(self, elapsed_ns, declared_prompt_tokens=None, request_succeeded=True):
        complete = self.done and self.finish_reason is not None and self.first_token_ns is not None
        actual = self.usage["prompt_tokens"] if self.usage else None
        counts = {"reported_prompt_tokens": actual, "declared_prompt_tokens": declared_prompt_tokens}
        deadlines = {}
        for name, count in counts.items():
            if count is None:
                continue
            deadline = 10_000_000_000 + count * 1_000_000
            # Failed/no-token requests never become a passing latency sample.
            margin = None if self.first_token_ns is None else deadline - self.first_token_ns
            deadlines[name] = dict(deadline_ns=deadline, first_token_margin_ns=margin,
                                   first_token_received_in_time=None if margin is None else margin >= 0,
                                   request_passed=request_succeeded and complete and margin is not None and margin >= 0)
        return dict(complete=complete, ttft_ns=self.first_token_ns,
                    first_content_ns=self.first_content_ns, first_reasoning_ns=self.first_reasoning_ns,
                    last_token_ns=self.last_token_ns, elapsed_ns=elapsed_ns,
                    finish_reason=self.finish_reason, done=self.done, usage=self.usage,
                    text_events=self.text_events, event_count=self.event_count, sla=deadlines,
                    engine_prefill_tps=None, engine_decode_tps=None, mtp_engagement_verified=False)


def receive_events(response, clock, retain, maximum_bytes=64 * 1024**2):
    """Yield complete SSE data records with time at receipt of their delimiter.

    Keep original bytes. An unterminated event at EOF is not a complete event.
    The clock is sampled before retention/parsing. LF and CRLF are supported.
    """
    data, count = [], 0
    while True:
        raw = response.readline(1024**2 + 1)
        observed = clock()
        if not raw:
            if data:
                raise ValueError("Truncated SSE event")
            return
        count += len(raw)
        if len(raw) > 1024**2 or count > maximum_bytes:
            raise ValueError("SSE response exceeds capture bound")
        retain(raw, observed)
        line = raw.decode("utf-8").rstrip("\r\n")
        if not line:
            if data:
                yield "\n".join(data), observed
                data = []
        elif line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))
