#!/usr/bin/env python3
"""Exercise the actual request CLI against exact Bonsai 9B tokenizer metadata.

Usage: check_bonsai9.py /ABS/darkbloom-cluster-pair-check /ABS/MODEL_METADATA
No weights, model runtime, network, or GPU are used. The input directory needs
the registered manifest, tokenizer.json, tokenizer_config.json and chat template.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    binary, model = (Path(value).resolve(strict=True) for value in sys.argv[1:])
    expected_manifest = "c226d5cf4ecea1c6f299c2a8ebaa8686a89be12750b45fa6fc910cb078b19c13"
    assert hashlib.sha256((model / "manifest.json").read_bytes()).hexdigest() == expected_manifest
    model_id = "registered_ternary_bonsai_2_9b"
    checks = []
    with tempfile.TemporaryDirectory(prefix="bonsai9-prompt-") as temporary:
        root = Path(temporary)
        counter = 0

        def request(text, *, raw=False, count=None, selected=None, directory=model, refusal=None):
            nonlocal counter
            counter += 1
            prompt, output = root / f"prompt-{counter}.txt", root / f"request-{counter}.json"
            prompt.write_text(text, encoding="utf-8")
            command = [str(binary), "request", "--output", str(output), "--chunk-size", "512",
                       "--output-count", "128", "--model-dir", str(directory),
                       "--raw-text-file" if raw else "--user-text-file", str(prompt)]
            if count is not None:
                command += ["--prompt-tokens", str(count)]
            if selected is not None:
                command += ["--model-id", selected]
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if refusal is not None:
                assert result.returncode != 0 and refusal in result.stderr + result.stdout, result
                assert not output.exists()
                return None
            assert result.returncode == 0, result.stderr
            value = json.loads(output.read_text())
            assert value["modelID"] == model_id
            assert value["profileID"] == model_id + "_greedy_generation_v1"
            assert all(0 <= token < 248320 for token in value["promptTokenIDs"])
            assert value["promptSource"]["tokenizerSHA256"] == hashlib.sha256(
                (model / "tokenizer.json").read_bytes()).hexdigest()
            return value

        text = "Explain why the Moon has phases."
        prefix = "<|im_start|>user\n"
        suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        chat = request(text)
        raw = request(prefix + text + suffix, raw=True)
        assert chat["promptTokenIDs"] == raw["promptTokenIDs"]
        assert chat["promptSource"]["matchesArtifactChatTemplate"] is True
        checks.append("exact artifact chat template and literal wrapper token parity")
        prefix_ids = request(prefix, raw=True)["promptTokenIDs"]
        suffix_ids = request(suffix, raw=True)["promptTokenIDs"]
        for count in (1024, 8193, 16384, 32768):
            value = request(text, count=count)
            tokens = value["promptTokenIDs"]
            assert len(tokens) == count
            assert tokens[:len(prefix_ids)] == prefix_ids and tokens[-len(suffix_ids):] == suffix_ids
            assert value["promptSource"]["bodyTokenCount"] == count - len(prefix_ids) - len(suffix_ids)
        checks.append("exact prompt lengths preserve prefix and suffix through 32768 tokens")
        request(text, selected="registered_ternary_bonsai_2_27b", refusal="tokenizer in --model-dir belongs")
        checks.append("crossed Bonsai model identity refused")
        changed = root / "changed"
        changed.mkdir()
        for name in ("manifest.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"):
            shutil.copy2(model / name, changed / name)
        for name in ("manifest.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"):
            path = changed / name
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            request(text, directory=changed, refusal="not a registered model" if name == "manifest.json"
                    else f"{name} differs from the registered manifest")
            path.write_bytes(original)
        checks.append("changed manifest and each tokenizer metadata file refused before output")
    print(json.dumps({"passed": True, "manifestSHA256": expected_manifest, "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
