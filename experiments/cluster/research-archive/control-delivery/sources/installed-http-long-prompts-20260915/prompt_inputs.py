"""Only pinned tokenizer metadata and licensed source text; never weights."""
import hashlib
import os
from pathlib import Path
import stat

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
MODEL = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
PINS = {
    'tokenizer': (MODEL / 'tokenizer.json', 19989343, '87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4'),
    'template': (MODEL / 'chat_template.jinja', 7756, 'a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715'),
    'config': (MODEL / 'tokenizer_config.json', 1139, 'e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182'),
    'source': (ROOT / 'prefill-development-workloads-draft/prompts/dev01-module-trees.txt', 116037, '4b7a6137b02dc05cbdf976fc8297cd4e5bf5e8be7e4cd6f4bdf5df3c3e350626'),
    'license': (ROOT / 'prefill-development-workloads-draft/LICENSE-MLX.txt', 1066, 'ccfab7ccb2ea306f71531c8ca77bb55507606cd90768b1e32b8b52ab5b48cf01'),
}

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def load_pinned():
    result = {}
    for name, (path, size, digest) in PINS.items():
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_size != size:
                raise ValueError('Pinned input shape differs: ' + name)
            parts, remaining = [], size + 1
            while remaining:
                part = os.read(fd, min(remaining, 65536))
                if not part:
                    break
                parts.append(part); remaining -= len(part)
            raw = b''.join(parts)
            after, named = os.fstat(fd), os.lstat(path)
            identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if identity(before) != identity(after) or identity(after) != identity(named) or len(raw) != size or sha(raw) != digest:
                raise ValueError('Pinned input changed: ' + name)
            result[name] = raw
        finally:
            os.close(fd)
    return result

def request(prompt):
    return dict(model='Qwen3.5-9B', messages=[dict(role='user', content=prompt)],
                stream=True, stream_options=dict(include_usage=True), max_tokens=128,
                temperature=0, top_p=1, top_k=0, repetition_penalty=1,
                presence_penalty=0, frequency_penalty=0, enable_thinking=False,
                reasoning_parser='qwen3')
