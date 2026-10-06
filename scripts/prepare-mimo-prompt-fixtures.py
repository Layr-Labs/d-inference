#!/usr/bin/env python3
"""Fetch only four public, immutable metadata fixtures; never model weights or credentials."""

import argparse
import hashlib
from pathlib import Path
import stat
import urllib.parse
import urllib.request

REPOSITORY = "XiaomiMiMo/MiMo-V2.6-Flash-RL"
REVISION = "5711b268169967567844e1e560e8a3966da959b1"
PINS = {
    "config.json": "61bea4a0f7a0dd8969f8cae528761e26b697dd12ff63e98804c3f0945492e621",
    "tokenizer.json": "ff15eb925890d6b71b5160de4b846fbd13178438ab463b38ecc953e8cd1dcb3e",
    "tokenizer_config.json": "413a7845f52943ccf4de0e5c838414507d16c44dbf573da9e20bc8902b384d06",
    "chat_template.jinja": "853650bee57bf95020373e4c928bd5a4b41b9915adf964a77711d2b49a291887",
}
CORPUS_SHA256 = "66e6a49a23509fbc99e5389fa4687f2b6175f96d05d7a8be0f323bf4986049bb"
MAXIMUM = 128 * 1024 * 1024


def checked_bytes(data, expected, maximum):
    if len(data) > maximum or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("fixture size or SHA-256 mismatch")
    return data


def public_metadata(name):
    # Fixed allowlist and immutable commit; no Hub login or token lookup.
    if name not in PINS:
        raise ValueError("not an approved metadata fixture")
    url = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}"
    request = urllib.request.Request(url, headers={"User-Agent": "darkbloom-fixture-check/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        if urllib.parse.urlsplit(response.geturl()).scheme != "https":
            raise ValueError("insecure fixture redirect")
        return response.read(MAXIMUM + 1)


def prepare(output, corpus, download=public_metadata):
    if corpus.is_symlink() or not stat.S_ISREG(corpus.stat().st_mode):
        raise ValueError("corpus must be an ordinary file")
    with corpus.open("rb") as source:
        checked_bytes(source.read((1 << 20) + 1), CORPUS_SHA256, 1 << 20)
    # Fresh namespace only: do not overwrite an old attempt or follow its link.
    if output.exists() or output.is_symlink():
        raise FileExistsError("fixture output already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(mode=0o700)
    output = output.resolve(strict=True)
    for name, digest in PINS.items():
        data = checked_bytes(download(name), digest, MAXIMUM)
        with (output / name).open("xb") as destination:
            destination.write(data)
        (output / name).chmod(0o600)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-env", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    corpus = root / "fixtures/prompt-contract/mimo-v26-additional20.json"
    output = prepare(args.output, corpus)
    lines = [f"MIMO_PROMPT_ARTIFACT_DIRECTORY={output}",
             f"MIMO_PROMPT_REFERENCE_VECTORS={corpus}"]
    if any("\n" in line or "\r" in line for line in lines):
        raise ValueError("invalid environment path")
    if args.github_env is not None:
        with args.github_env.open("a", encoding="utf-8") as destination:
            destination.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
