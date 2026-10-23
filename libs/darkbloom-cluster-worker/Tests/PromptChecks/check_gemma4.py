#!/usr/bin/env python3
"""Check all three exact Gemma catalog tokenizers through the actual request CLI.

Usage: check_gemma4.py /ABS/darkbloom-cluster-pair-check /ABS/TOKENIZER_FIXTURES
Only registered tokenizer metadata is used; no model weights or GPU.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    binary, fixtures = (Path(value).resolve(strict=True) for value in sys.argv[1:])
    variants = [('gemma-4-26b-qat-4bit', 'registered_gemma4_26b_qat_4bit'),
                ('gemma-4-26b-8bit', 'registered_gemma4_26b_8bit'),
                ('gemma-4-26b', 'registered_gemma4_26b')]
    rows = []
    with tempfile.TemporaryDirectory(prefix='gemma4-prompt-') as temporary:
        scratch = Path(temporary)
        ordinal = 0
        for catalog, model_id in variants:
            model = fixtures/catalog
            def request(text, raw=False, count=None):
                nonlocal ordinal
                ordinal += 1
                prompt = scratch/f'{ordinal}.txt'
                output = scratch/f'{ordinal}.json'
                prompt.write_text(text)
                command = [str(binary), 'request', '--model-dir', str(model),
                           '--raw-text-file' if raw else '--user-text-file', str(prompt),
                           '--output-count', '128', '--chunk-size', '512', '--output', str(output)]
                if count is not None: command += ['--prompt-tokens', str(count)]
                result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                assert result.returncode == 0, result.stderr
                value = json.loads(output.read_text())
                assert value['modelID'] == model_id
                assert value['promptSource']['tokenizerSHA256'] == hashlib.sha256((model/'tokenizer.json').read_bytes()).hexdigest()
                return value
            prefix = '<bos>\n<|turn>user\n'
            suffix = '<turn|>\n<|turn>model\n<|channel>thought\n<channel|>'
            for text in ['Explain why the Moon has phases.', 'Remember the code.\n paper paper\nThe code is K7M2V9.\nReply only with the code.']:
                chat = request(text)
                assert chat['promptSource']['matchesArtifactChatTemplate'] is True
                assert chat['promptTokenIDs'] == request(prefix+text+suffix, raw=True)['promptTokenIDs']
            first = request(prefix, raw=True)['promptTokenIDs']
            last = request(suffix, raw=True)['promptTokenIDs']
            for count in (1024, 4096, 16384, 32768):
                value = request('Explain the Moon.', count=count)
                tokens = value['promptTokenIDs']
                assert len(tokens) == count
                assert tokens[:len(first)] == first and tokens[-len(last):] == last
                assert value['promptSource']['bodyTokenCount'] == count-len(first)-len(last)
            rows.append({'catalog': catalog, 'model_id': model_id, 'template_cases': 2,
                         'fixed_lengths': [1024,4096,16384,32768], 'passed': True})
    print(json.dumps({'passed': True, 'variants': rows}, indent=2))


if __name__ == '__main__': main()
