#!/usr/bin/env python3
"""Prepare a small native target with the genuine pinned MiMo audio codec."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import subprocess
import sys

VIDEO_URL = "https://model-assets.openrouter.ai/model-examples/bytedance/seedance-2.5-20260807/bd6114c8-ef63-47e2-9399-d89271243fe4/original-0.mp4"
BASE_URL = "https://models.darkbloom.ai/v2/mimo-v2.6-flash-mopd--3012243b1fbc/2026-09-28-r1"
# Published immutable metadata and codec. These are test inputs, never executed
# code. The production loader independently authenticates the selected sidecar.
FILES = {
    "openrouter-aac.mp4": (6934922, "dc11648bd3546cd0a37ecc1077ccc426d42c409fe4822ece0354eb250804431e"),
    'audio_tokenizer/chat_template.jinja': (
        5588, 'cf1a0a0e5cbc6a6a1b609f19f6db5483fddf978e6c8c8453ca2549bed02b7425'),
    'audio_tokenizer/config.json': (
        1215, 'e0702adae37947e0c980c38bae58ffa0d48bd492d523afe814aa4d73f008c7d1'),
    'audio_tokenizer/generation_config.json': (
        149, '5e14358a9bd50424310fe2c5afabf6a131c3a9b452c9322f7d9ee6f9ff6b8ef9'),
    'audio_tokenizer/model.safetensors': (
        1872618384, '077033345d80eef3a315e8d394e0589667e80e4cdaba9bc5a7488410c6657265'),
    'audio_tokenizer/tokenizer_config.json': (
        6059, 'ac41378c3257a15e31d5afa7a8e3e6ca9c2ec6702adf7a93064f8dae384939df'),
    'chat_template.jinja': (
        3867, '11ea52e156de38a458e6b7720ad45915d65b97d4ec979a09f55e3c9bd1b4d059'),
    'config.json': (
        133013, '35b6e3d4543b65e6fa9d6174e2260d9ac1d3ea1e5acb9955d9fe9f2b815d13d4'),
    'generation_config.json': (
        195, 'eecf00d9701921271c904a916c425ba6db61bcd190902e200d0a322bfd5572dd'),
    'tokenizer.json': (
        11423819, '8d4b7746684abeca0980d9b740e761c8e135cbf927feab55b377d07a6cca83e8'),
    'tokenizer_config.json': (
        893, '355fbe16c4b032ee8c65ca7211575af4b956531eca860a584200d80b749d2d89'),
}


def verify(path, size, digest):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != size:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == digest


def prepare(cache, output):
    def fetch(item):
        relative, (size, digest) = item
        path = cache / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if verify(path, size, digest):
            return
        temporary = path.with_name(path.name + ".download")
        if temporary.is_symlink():
            raise ValueError("unexpected download symlink")
        subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                        "--retry", "3", "--max-time", "900",
                        (VIDEO_URL if relative == "openrouter-aac.mp4" else BASE_URL + "/" + relative), "--output", str(temporary)], check=True)
        if not verify(temporary, size, digest):
            raise ValueError("MiMo audio fixture digest mismatch: " + relative)
        os.replace(temporary, path)
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(fetch, FILES.items()))
    subprocess.run([sys.executable, str(Path(__file__).with_name("prepare-mimo-provider-fixtures.py")),
                    "--output", str(output), "--audio-source", str(cache)], check=True)
    return output.resolve() / "tiny-bf16"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-env", type=Path)
    args = parser.parse_args()
    root = prepare(args.cache, args.output)
    line = "MIMO_V26_MANAGED_AUDIO_FIXTURE_ROOT=" + str(root)
    if "\n" in line or "\r" in line:
        raise ValueError("invalid environment path")
    video_line = "MIMO_V26_MANAGED_AAC_VIDEO_FIXTURE=" + str(args.cache.resolve() / "openrouter-aac.mp4")
    if "\n" in video_line or "\r" in video_line:
        raise ValueError("invalid environment path")
    if args.github_env:
        with args.github_env.open("a") as stream:
            stream.write(line + "\n" + video_line + "\n")
    print(line)
    print(video_line)


if __name__ == "__main__":
    main()
