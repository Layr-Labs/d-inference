"""Bounded local inputs for one explicit, authenticated text request."""

import json
import math
import os
from pathlib import Path
import stat
from urllib.parse import urlsplit


def snapshot(path, maximum, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= maximum
                or (private and (before.st_uid != os.getuid()
                                 or stat.S_IMODE(before.st_mode) != 0o600))):
            raise ValueError("Invalid bounded input file")
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after, named = os.fstat(fd), os.lstat(path)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns,
                              s.st_ctime_ns, s.st_mode, s.st_uid)
        if (identity(before) != identity(after) or identity(after) != identity(named)
                or len(data) != before.st_size):
            raise ValueError("Input changed during bounded read")
        return bytes(data)
    finally:
        os.close(fd)


def inputs(endpoint, model, prompt_file, token_file, timeout, declared_prompt_tokens):
    url = urlsplit(endpoint)
    if (url.scheme not in ("http", "https") or not url.hostname
            or url.username or url.password or url.query or url.fragment
            or url.path != "/v1/chat/completions"
            or any(ord(c) < 33 or ord(c) == 127 for c in endpoint)):
        raise ValueError("Use an explicit credential-free chat-completions URL")
    _ = url.port
    if (type(timeout) not in (int, float) or not math.isfinite(timeout)
            or not 0 < timeout <= 300):
        raise ValueError("Timeout must be in (0, 300] seconds")
    if declared_prompt_tokens is not None and (type(declared_prompt_tokens) is not int
            or not 1 <= declared_prompt_tokens <= 8192):
        raise ValueError("Declared prompt count must be in 1...8192")
    if (type(model) is not str or not 0 < len(model.encode()) <= 512
            or any(ord(c) < 33 or ord(c) == 127 for c in model)):
        raise ValueError("Expected an explicit public model ID")
    secret = snapshot(token_file, 4096, private=True)
    if secret.endswith(b"\n"):
        secret = secret[:-1]
    if not 16 <= len(secret) <= 4096 or any(c < 33 or c > 126 for c in secret):
        raise ValueError("Invalid private bearer token")
    prompt_bytes = snapshot(prompt_file, 512 * 1024)
    prompt = prompt_bytes.decode("utf-8")
    if not prompt.strip() or "\0" in prompt:
        raise ValueError("Expected nonempty UTF-8 prompt text")
    # Only fields verified in the current local HTTP decoder/translation path.
    request = dict(model=model, messages=[dict(role="user", content=prompt)],
                   stream=True, stream_options=dict(include_usage=True), max_tokens=128,
                   temperature=0, top_p=1, top_k=0, repetition_penalty=1,
                   presence_penalty=0, frequency_penalty=0, enable_thinking=False,
                   reasoning_parser="qwen3")
    encoded = (json.dumps(request, ensure_ascii=False, separators=(",", ":"),
                          allow_nan=False) + "\n").encode("utf-8")
    if secret in encoded or secret in endpoint.encode():
        raise ValueError("Credential overlaps retained request data")
    return url, secret, prompt_bytes, encoded


def private_file(path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                            | os.O_NOFOLLOW, 0o600), "wb")


def write_json(path, value):
    with private_file(path) as output:
        output.write((json.dumps(value, indent=2, allow_nan=False) + "\n").encode())
