"""Content-first timing layered on the unchanged repository SSE observation."""

from streaming_latency import StreamObservation, strict_json


class ContentObservation(StreamObservation):
    def __init__(self, model):
        super().__init__()
        self.model = model
        self.response_id = None

    def accept(self, payload, elapsed_ns):
        if payload != "[DONE]":
            event = strict_json(payload)
            if not isinstance(event, dict) or event.get("error") is not None:
                raise ValueError("SSE error or invalid object")
            identifier = event.get("id")
            if (event.get("object") != "chat.completion.chunk" or event.get("model") != self.model
                    or type(identifier) is not str or not 0 < len(identifier.encode()) <= 512
                    or (self.response_id is not None and identifier != self.response_id)):
                raise ValueError("Chat response identity differs")
            self.response_id = identifier
            choices = event.get("choices")
            if type(choices) is not list or len(choices) > 1:
                raise ValueError("Expected one chat choice")
            for choice in choices:
                if type(choice) is not dict or type(choice.get("index")) is not int or choice["index"] != 0:
                    raise ValueError("Invalid chat choice index")
                delta = choice.get("delta")
                if type(delta) is not dict:
                    raise ValueError("Invalid chat delta")
                if choice.get("finish_reason") is not None and choice["finish_reason"] not in ("stop", "length"):
                    raise ValueError("Unexpected current-profile finish reason")
                for key in ("content", "reasoning_content", "reasoning"):
                    if delta.get(key) is not None and type(delta[key]) is not str:
                        raise ValueError("Invalid text delta")
            usage = event.get("usage")
            if usage is not None:
                if (type(usage) is not dict or set(usage) != {"prompt_tokens", "completion_tokens", "total_tokens"}
                        or any(type(v) is not int for v in usage.values())
                        or not 1 <= usage["prompt_tokens"] <= 8192
                        or not 0 <= usage["completion_tokens"] <= 128
                        or usage["total_tokens"] != usage["prompt_tokens"] + usage["completion_tokens"]):
                    raise ValueError("Invalid current-profile usage")
        super().accept(payload, elapsed_ns)

    def content_summary(self, elapsed_ns, declared, succeeded):
        terminal = self.done and self.finish_reason is not None
        actual = None if self.usage is None else self.usage["prompt_tokens"]
        sla = {}
        for name, count in (("reported_prompt_tokens", actual), ("declared_prompt_tokens", declared)):
            if count is None:
                continue
            deadline = 10_000_000_000 + count * 1_000_000
            margin = None if self.first_content_ns is None else deadline - self.first_content_ns
            sla[name] = dict(deadline_ns=deadline, content_margin_ns=margin,
                            content_received_in_time=None if margin is None else margin >= 0,
                            request_passed=succeeded and terminal and margin is not None and margin >= 0)
        return dict(stream_terminal_complete=terminal, ttft_ns=self.first_content_ns,
                    first_content_ns=self.first_content_ns, first_reasoning_ns=self.first_reasoning_ns,
                    first_text_ns=self.first_token_ns, last_text_ns=self.last_token_ns,
                    elapsed_ns=elapsed_ns, finish_reason=self.finish_reason, done=self.done,
                    usage=self.usage, declared_prompt_tokens=declared,
                    text_events=self.text_events, event_count=self.event_count,
                    content_sla=sla, requested_output_tokens=128,
                    reported_output_is_128=self.usage is not None and self.usage["completion_tokens"] == 128,
                    engine_prefill_tps=None, engine_decode_tps=None)
