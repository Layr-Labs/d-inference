"""Bounded HTTP reads and an explicitly configured synthetic test-only probe."""
from dataclasses import dataclass
import http.client
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_RESPONSE_BYTES = 1_048_576
SYNTHETIC_ANSWER = "STARTUP_OK"


def validate_base_url(value):
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in {"", "/"}):
        raise ValueError("base URL must be an HTTP(S) origin without credentials, path, query or fragment")
    _ = parsed.port  # reject malformed port values before any network access
    return value.rstrip("/")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@dataclass
class Result:
    status: int | None
    outcome: str
    body: object = None
    observation: dict | None = None

    def public(self):
        # Never expose response bodies, error strings, request data or headers.
        return {"status": self.status, "outcome": self.outcome, **({"observation": self.observation} if self.observation else {})}


class Client:
    def __init__(self, base_url):
        self.base_url = validate_base_url(base_url)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, timeout, *, api_key=None, payload=None):
        headers = {"Accept": "application/json", "Cache-Control": "no-cache"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        if api_key and (not isinstance(api_key, str) or not all(33 <= ord(char) <= 126 for char in api_key)):
            return Result(None, "invalid_credentials")
        if api_key:
            headers["Authorization"] = "Bearer " + api_key
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers)
        response = None
        deadline = time.monotonic() + timeout
        try:
            try:
                response = self.opener.open(request, timeout=timeout)
            except urllib.error.HTTPError as error:
                response = error
            status = response.code
            chunks = []
            size = 0
            while size <= MAX_RESPONSE_BYTES:
                if time.monotonic() >= deadline:
                    return Result(status, "request_deadline")
                chunk = response.read1(min(65536, MAX_RESPONSE_BYTES + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            if time.monotonic() > deadline:
                return Result(status, "request_deadline")
            raw = b"".join(chunks)
            if len(raw) > MAX_RESPONSE_BYTES:
                return Result(status, "response_too_large")
            try:
                return Result(status, "json", json.loads(raw))
            except (ValueError, UnicodeError):
                return Result(status, "invalid_json")
        except (OSError, urllib.error.URLError, TimeoutError, http.client.HTTPException):
            return Result(None, "transport_error")
        finally:
            if response is not None:
                response.close()


@dataclass(repr=False)
class TestProbe:
    api_key: str
    max_attempts: int = 3

    @classmethod
    def from_file(cls, path, base_url):
        # No free-form prompts or production key flags. The operator must supply
        # an explicit disposable-test config AND an env-sourced authorized key.
        with open(path, encoding="utf-8") as source:
            config = json.load(source)
        if not isinstance(config, dict) or config.get("environment") != "disposable-test":
            raise ValueError("inference config must declare environment=disposable-test")
        if validate_base_url(config.get("base_url", "")) != base_url:
            raise ValueError("inference config target does not match the observed origin")
        hostname = urllib.parse.urlsplit(base_url).hostname.lower().rstrip(".")
        if hostname in {"api.darkbloom.dev", "api.darkbloom.ai", "console.darkbloom.dev"}:
            raise ValueError("synthetic startup inference is refused for known production origins")
        key_env = config.get("api_key_env", "")
        if not re.fullmatch(r"[A-Z][A-Z0-9_]{0,95}", key_env):
            raise ValueError("inference config requires an API-key environment variable name")
        api_key = os.environ.get(key_env, "")
        if not api_key or not all(33 <= ord(char) <= 126 for char in api_key):
            raise ValueError("configured test API-key environment variable is missing or invalid")
        return cls(api_key)

    def run(self, client, model, timeout):
        started = time.monotonic()
        result = client.request("/v1/chat/completions", timeout, api_key=self.api_key, payload={
            "model": model, "messages": [{"role": "user", "content": "Reply with exactly STARTUP_OK."}],
            "max_tokens": 32, "stream": False,
        })
        body = result.body if isinstance(result.body, dict) else {}
        choices = body.get("choices")
        first = choices[0] if isinstance(choices, list) and choices and isinstance(choices[0], dict) else {}
        message = first.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        available = (result.status == 200 and "error" not in body and body.get("model") == model
                     and first.get("finish_reason") in {"stop", "length"}
                     and isinstance(content, str) and bool(content.strip()))
        return {**result.public(), "duration_ms": round((time.monotonic() - started) * 1000, 3),
                "availability_success": available, "response_model_matches": body.get("model") == model,
                "synthetic_answer_matches": content.strip() == SYNTHETIC_ANSWER if available else None}
