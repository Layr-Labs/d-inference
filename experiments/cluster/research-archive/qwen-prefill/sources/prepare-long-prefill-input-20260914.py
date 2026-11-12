#!/usr/bin/env python3
"""Prepare a deterministic English-prose diagnostic, without loading a model."""
import hashlib
import json
import platform
import sys
from pathlib import Path
import tokenizers
from tokenizers import Tokenizer

BASE = Path('/Users/developer/DarkbloomDev/cluster-research')
MODEL = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
DEST = BASE / 'long-prefill-input-20260914'
TOKENIZER_SHA = '87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    assert not DEST.exists()
    raw = (MODEL / 'tokenizer.json').read_bytes()
    assert sha(raw) == TOKENIZER_SHA
    assert tokenizers.__version__ == '0.22.2'
    paragraphs = [
        'The team begins with a complete model on one computer. Each request owns its sequence state, and every prompt starts from an empty state. The experiment records the model identity and the exact input before starting work. Loading the weights is a separate operation from processing the prompt. A result can therefore explain which work its duration includes.',
        'The first computer processes the earlier layers and sends the resulting hidden values to the second computer. The second computer processes the remaining layers in their original order. Each layer keeps its full width. Both computers must agree on the position of every token, because attention and recurrent updates depend on the sequence already processed.',
        'A long prompt is divided into consecutive pieces. The first piece begins at position zero, and the next begins immediately after it. A computer may prepare the following piece while its partner finishes the current piece, but the queue has a fixed limit. A received message is not evidence that the corresponding computation has finished.',
        'To check the arithmetic, the team compares a divided model with a complete model using the same pieces of the same prompt. The comparison includes all final vocabulary values and every owned state component. Selecting the same word alone is insufficient: different numerical results can still select the same word. The saved evidence distinguishes direct comparisons from metadata checks.',
        'Communication can fail between any two steps. A request that fails must release its pending buffers and retire its state. A new request receives a new identity and starts with no inherited tokens. The experiment deliberately introduces a failure, then attempts a fresh request with the resident weights. This tests whether recovery preserves ownership.',
        'A performance claim requires a stated workload and an appropriate comparison. The team records prompt length, chunk length, output count, precision and machine configuration. It repeats the measured workload after a fixed preparation phase. Trials alternate their order so that temperature and previous work are less likely to favor one configuration.',
        'Memory observations answer different questions. Resident process memory describes one part of the system, while device allocation statistics describe another. Sparse observations may miss a brief maximum. The experiment retains both measurements when available and labels missing measurements explicitly. A formula for named tensors does not include all temporary workspaces or operating system costs.',
        'The final report separates what was observed from what remains a hypothesis. A test on one computer does not establish the speed of a physical link between two computers. A small model can expose a protocol bug without predicting the throughput of a larger model. Each successful test narrows the next question and leaves its inputs available for independent review.',
    ]
    text = 'Technical notebook for a cluster inference correctness experiment.\n\n'
    for section in range(1, 33):
        text += 'Notebook entry %d.\n' % section
        text += '\n\n'.join(paragraphs[section % 8:] + paragraphs[:section % 8]) + '\n\n'
    tokenizer = Tokenizer.from_str(raw.decode('utf-8'))
    all_ids = tokenizer.encode(text, add_special_tokens=False).ids
    assert len(all_ids) > 8192
    prompt = all_ids[:8192]
    assert len(prompt) == 8192 and all(type(x) is int and 0 <= x < 248320 for x in prompt)
    prompt_raw = json.dumps(prompt, separators=(',', ':')).encode('ascii') + b'\n'
    assert len(prompt_raw) <= 65536
    prefix = tokenizer.decode(prompt, skip_special_tokens=False).encode('utf-8')
    DEST.mkdir(mode=0o700)
    files = {'source-text.txt': text.encode('utf-8'), 'prompt-8192.json': prompt_raw,
             'decoded-prefix.txt': prefix, 'preparation.py': Path(__file__).read_bytes()}
    for name, data in files.items():
        (DEST / name).write_bytes(data)
    receipt = dict(schemaVersion=1, kind='long_prefill_prose_input',
        promptCount=8192, sourceTokenCount=len(all_ids), vocabularySize=248320,
        inputKind='deterministic_generated_English_prose_with_repeated_paragraphs',
        representativeWorkloadClaim=False, modelInferencePerformed=False,
        chatTemplateApplied=False, addSpecialTokens=False,
        tokenizerJSONSHA256=TOKENIZER_SHA, tokenizerVersion=tokenizers.__version__,
        pythonVersion=platform.python_version(), pythonExecutableSHA256=sha(Path(sys.executable).read_bytes()),
        promptTokenIDsSHA256=sha(','.join(map(str, prompt)).encode('ascii')),
        files={name:dict(byteCount=len(data), sha256=sha(data)) for name,data in files.items()})
    encoded = json.dumps(receipt, indent=2, sort_keys=True).encode('utf-8') + b'\n'
    (DEST / 'tokenization.json').write_bytes(encoded)
    print(json.dumps(dict(promptCount=8192, sourceTokenCount=len(all_ids),
        promptFileSHA256=sha(prompt_raw), originSHA256=sha(encoded))))

if __name__ == '__main__':
    main()
