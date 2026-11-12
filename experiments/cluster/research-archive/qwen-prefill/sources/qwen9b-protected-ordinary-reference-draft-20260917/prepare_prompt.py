"""Deferred root-only tokenizer metadata operation; never loads model weights."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import stat
import sys

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE / 'package'))
from binding_common import parse, require, same
from binding_inputs import snapshot
from reference_inputs import write_json, write_new

TEXT = ('Explain how a careful gardener decides when to water a young tree. Describe the observations, '
        'the difference between dry surface soil and dry roots, and one simple way to check moisture. '
        'Use clear ordinary language and connect each action to its purpose. ')
MANIFEST = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'
ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
TOKENIZER = '87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4'


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--model-directory', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(args.model_directory.resolve() == args.model_directory and args.output.is_absolute()
            and args.output.parent.resolve() == args.output.parent, 'Canonical metadata/output paths')
    manifest = snapshot(args.model_directory / 'manifest.json', 4*1024**2)
    same(manifest['sha256'], MANIFEST, 'Exact registered 9B manifest')
    data = parse(manifest['raw']); same(data['aggregate_sha256'], ARTIFACT, 'Exact registered 9B artifact')
    row = [r for r in data['files'] if r['path'] == 'tokenizer.json']
    require(len(row) == 1 and row[0]['sha256'] == TOKENIZER and row[0]['size_bytes'] == 19989343,
            'Exact registered tokenizer declaration')
    path = args.model_directory / 'tokenizer.json'; named = path.lstat()
    require(stat.S_ISREG(named.st_mode) and named.st_nlink == 1, 'Regular single-link tokenizer')
    tokenizer = snapshot(path, 32*1024**2)
    same(tokenizer['sha256'], TOKENIZER, 'Actual tokenizer bytes')
    same(tokenizer['size_bytes'], 19989343, 'Actual tokenizer size')
    from tokenizers import Tokenizer
    all_ids = Tokenizer.from_str(tokenizer['raw'].decode('utf-8')).encode(TEXT, add_special_tokens=True).ids
    require(32 < len(all_ids) <= 1024 and all(type(x) is int and 0 <= x < 248320 for x in all_ids),
            'Tokenizer-derived prompt geometry')
    selected = all_ids[:32]
    for source, saved, cap in [(args.model_directory / 'manifest.json', manifest, 4*1024**2),
                               (path, tokenizer, 32*1024**2)]:
        again = snapshot(source, cap, keep=False)
        same({k:v for k,v in saved.items() if k != 'raw'}, {k:v for k,v in again.items() if k != 'raw'}, 'Metadata changed during tokenization')
    import hashlib
    digest = lambda raw: hashlib.sha256(raw).hexdigest()
    raw = (json.dumps(selected, separators=(',', ':')) + '\n').encode()
    args.output.mkdir(mode=0o700)
    write_new(args.output / 'prompt.ids.json', raw)
    write_json(args.output / 'prompt-receipt.json', dict(schema='qwen9b_protected_reference_tokenizer_packet_v1',
        manifestSHA256=MANIFEST, artifactSHA256=ARTIFACT, tokenizerSHA256=TOKENIZER, tokenizerBytes=19989343,
        generatorSHA256=digest(Path(__file__).read_bytes()), tokenizerLibrary='tokenizers',
        tokenizerVersion=importlib.metadata.version('tokenizers'), authoredText=TEXT, authoredTextSHA256=digest(TEXT.encode()),
        addSpecialTokens=True, chatTemplateApplied=False, selection='first_32_tokenizer_ids', allTokenIDs=all_ids,
        tokenIDs=selected, promptFileSHA256=digest(raw), promptCount=32,
        swiftTokenizerQualification=False, modelOrGPUExecuted=False))
    print(json.dumps(dict(prompt=str(args.output / 'prompt.ids.json'), sha256=digest(raw))))


if __name__ == '__main__':
    os.umask(0o077)
    main()
