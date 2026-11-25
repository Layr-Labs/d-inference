"""Construct two exact CPU-counted HTTP prompts from unique licensed source prefixes."""
import argparse
import json
import os
from pathlib import Path
import platform
import sys
from prompt_inputs import PINS, load_pinned, request, sha
from prompt_render import Renderer

HEADER = '''Read the following MLX source excerpt. In at most 100 words, give three concrete observations about parameter discovery, nested updates, and trainability. Name relevant supplied functions. If required implementation is outside the excerpt, say so; do not invent it or execute code.

Source: MLX, Apple Inc. and contributors, https://github.com/ml-explore/mlx
Commit: ce45c52505c8158ea48d2a54e8caae05efd86bfe
License follows and applies to the reproduced code.

'''
FOOTER = '\n\n[End of source excerpt. The final source fragment may be incomplete.]\n'

def choose(renderer, header, source, target):
    def candidate(end):
        text = header + source[:end].rstrip() + FOOTER
        rendered, ids = renderer.encode(text)
        return text, rendered, ids
    low, high = 1, len(source)
    # Bisection only guides a bounded search. Exact final encode, not an assumed
    # monotone BPE count or raw-prefix length, is the acceptance criterion.
    while low < high:
        middle = (low + high) // 2
        if len(candidate(middle)[2]) < target:
            low = middle + 1
        else:
            high = middle
    for end in range(max(1, low - 512), min(len(source), low + 512) + 1):
        text, rendered, ids = candidate(end)
        if len(ids) == target:
            return end, text, rendered, ids
    raise ValueError('No exact count near source boundary; do not pad or guess')

def save(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as f:
        f.write(data)
    return dict(path=path.name, bytes=len(data), sha256=sha(data))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    raw = load_pinned(); renderer = Renderer(raw)
    license_text = raw['license'].decode('utf-8')
    header = HEADER + license_text.rstrip() + '\n\nSOURCE MATERIAL\n\n'
    original = raw['source'].decode('utf-8')
    source = original.split('SOURCE MATERIAL\n\n', 1)[1]
    if any(x in header + source for x in ['<|im_start|>', '<|im_end|>', '<|endoftext|>', '<think>', '</think>']):
        raise ValueError('Source contains chat control markers')
    prepared = [choose(renderer, header, source, count) for count in [4096, 8192]]
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    results = []
    for target, (end, text, rendered, ids) in zip([4096, 8192], prepared):
        name = 'prompt-' + str(target)
        files = [save(args.output / (name + '.txt'), text.encode()),
                 save(args.output / (name + '.rendered.txt'), rendered.encode()),
                 save(args.output / (name + '.ids.json'), (json.dumps(ids, separators=(',', ':')) + '\n').encode()),
                 save(args.output / (name + '.request.json'), (json.dumps(request(text), ensure_ascii=False, separators=(',', ':')) + '\n').encode())]
        selected = source[:end].rstrip().encode()
        results.append(dict(targetTokens=target, pythonTemplatedTokenCount=len(ids),
            sourcePrefixCharacters=end, selectedSourceBytes=len(selected), selectedSourceSHA256=sha(selected),
            tokenIDsCommaSeparatedSHA256=sha(','.join(map(str, ids)).encode()),
            promptTemplateApplied=True, addGenerationPrompt=True, addSpecialTokens=False,
            thinkingEnabled=False, sourceRepeated=False, paddingUsed=False, files=files))
    receipt = dict(schema='installed_http_long_prompt_preparation_v1',
        inputs={name:dict(path=str(p), bytes=n, sha256=h) for name,(p,n,h) in PINS.items()},
        pythonVersion=platform.python_version(), pythonExecutable=str(Path(sys.executable).resolve()),
        pythonExecutableSHA256=sha(Path(sys.executable).read_bytes()),
        tokenizerVersion='0.22.2', jinjaVersion='3.1.6', modelVocabularySize=248320,
        tokenizerBaseEntries=248044, tokenizerEntriesWithAddedTokens=248077,
        fullPinnedJinjaMatchesExplicitSingleUserRendering=True,
        swiftTokenizerExecuted=False, serverPromptCountObserved=False,
        modelLoaded=False, networkUsed=False, representativeWorkloadClaim=False,
        physicalPerformanceQualified=False, fixtures=results)
    save(args.output / 'preparation.json', (json.dumps(receipt, indent=2) + '\n').encode())
    print(json.dumps(dict(output=str(args.output), counts=[x['pythonTemplatedTokenCount'] for x in results], swiftTokenizerExecuted=False, modelLoaded=False)))

if __name__ == '__main__':
    main()
