"""Tokenize pinned real-source development inputs, without loading any model."""

import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tokenizers
from tokenizers import Tokenizer

research = Path(__file__).resolve().parent.parent
draft = research / 'prefill-development-workloads-draft'
destination = research / 'prefill-development-inputs-20260914'
recipe_raw = (draft / 'recipes.json').read_bytes()
recipe_pin = '94869a94f623ce7cf969061a57efd3e98bc5486cba1c35f13823b4e17262c443'


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, raw):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as handle:
        handle.write(raw)
    return dict(path=str(path.relative_to(destination)), byteCount=len(raw), sha256=sha(raw))


assert sha(recipe_raw) == recipe_pin
recipe = json.loads(recipe_raw)
assert recipe['development_only'] and not recipe['qualification_workload']
assert tokenizers.__version__ == '0.22.2'
reference = recipe['tokenization_reference']
raw_tokenizer = Path(reference['tokenizer_path']).read_bytes()
assert sha(raw_tokenizer) == reference['tokenizer_sha256']
license_raw = (draft / recipe['license']['retained_path']).read_bytes()
assert sha(license_raw) == recipe['license']['sha256']
seen_sources = set()
raw_prompts = []
for row in recipe['workloads']:
    raw = (draft / row['raw_prompt']).read_bytes()
    assert len(raw) == row['raw_prompt_bytes'] and sha(raw) == row['raw_prompt_sha256']
    assert license_raw.strip() in raw
    for source in row['sources']:
        assert source['path'] not in seen_sources
        seen_sources.add(source['path'])
        blob = subprocess.run(['git', '-C', recipe['local_repository'], 'show',
            recipe['source_commit'] + ':' + source['path']], check=True, capture_output=True, timeout=10).stdout
        assert len(blob) == source['bytes'] and sha(blob) == source['sha256']
        assert raw.count(blob) == 1
    raw_prompts.append((row, raw))
assert len(raw_prompts) == 10 and len(seen_sources) == 68
tokenizer = Tokenizer.from_str(raw_tokenizer.decode('utf-8'))
assert tokenizer.get_vocab_size(with_added_tokens=True) == 248320

# Confirm the current tokenizer runtime reproduces the previously retained
# diagnostic IDs before using its settings for new, non-repeated source inputs.
old = research / 'long-prefill-input-20260914'
old_metadata = json.loads((old / 'tokenization.json').read_bytes())
old_text = (old / 'source-text.txt').read_bytes()
assert sha(old_text) == old_metadata['files']['source-text.txt']['sha256']
old_ids = tokenizer.encode(old_text.decode('utf-8'), add_special_tokens=False).ids[:8192]
old_encoded = json.dumps(old_ids, separators=(',', ':')).encode('ascii') + b'\n'
assert sha(old_encoded) == old_metadata['files']['prompt-8192.json']['sha256']

prepared = []
for row, raw in raw_prompts:
    ids = tokenizer.encode(raw.decode('utf-8'), add_special_tokens=False).ids
    assert len(ids) >= 8192
    selected = ids[:8192]
    assert len(selected) == 8192 and all(type(value) is int and 0 <= value < 248320 for value in selected)
    encoded = json.dumps(selected, separators=(',', ':')).encode('ascii') + b'\n'
    assert len(encoded) <= 65536
    prefix = tokenizer.decode(selected, skip_special_tokens=False).encode('utf-8')
    prepared.append((row, raw, encoded, prefix, len(ids), sha(','.join(map(str, selected)).encode('ascii'))))
assert len({row[2] for row in prepared}) == 10 and len({row[5] for row in prepared}) == 10
destination.mkdir(mode=0o700)
files = [save(destination / 'recipes.json', recipe_raw), save(destination / 'LICENSE-MLX.txt', license_raw),
         save(destination / 'preparation.py', Path(__file__).read_bytes())]
rows, details = [], []
for source, raw, encoded, prefix, source_count, token_pin in prepared:
    subdir = destination / source['id']
    subdir.mkdir(mode=0o700)
    source_file = save(subdir / 'source-text.txt', raw)
    tokens_file = save(subdir / 'prompt-8192.json', encoded)
    prefix_file = save(subdir / 'decoded-prefix.txt', prefix)
    files.extend((source_file, tokens_file, prefix_file))
    rows.append(dict(id=source['id'], prompt_sha256=tokens_file['sha256'], origin_sha256=recipe_pin))
    details.append(dict(id=source['id'], task_type=source['task_type'], sourceTokenCount=source_count,
                        promptTokenCount=8192, promptTokenIDsSHA256=token_pin, promptFile=tokens_file,
                        sourceText=source_file, decodedPrefix=prefix_file))
rows_raw = (json.dumps(rows, indent=2, sort_keys=True) + '\n').encode()
files.append(save(destination / 'prompt-rows.json', rows_raw))
receipt = dict(schema='prefill_development_tokenization_v1', developmentOnly=True,
               qualificationWorkload=False, representativeWorkloadClaim=False, modelInferencePerformed=False,
               nativeRequestsExecuted=False, actualNativeAdmissionPerformed=False,
               artifactAggregateSHA256='127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
               tokenizerJSONSHA256=sha(raw_tokenizer), tokenizerVersion=tokenizers.__version__, vocabularySize=248320,
               pythonVersion=platform.python_version(), pythonExecutableSHA256=sha(Path(sys.executable).read_bytes()),
               priorDiagnosticIDsReproducedExactly=True, chatTemplateApplied=False, addSpecialTokens=False,
               promptCount=10, tokensPerPrompt=8192, distinctRawTokenFiles=True, repeatedPaddingUsed=False,
               sourceFilesVerified=68, originRecipeSHA256=recipe_pin, sourceCommit=recipe['source_commit'],
               fullSourceFilesRetained=True, decodedPrefixMayEndInsideSourceExcerpt=True, workloads=details, files=files)
receipt_raw = (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode()
save(destination / 'tokenization.json', receipt_raw)
print(json.dumps(dict(directory=str(destination), receipt_sha256=sha(receipt_raw), prompts=10,
                      tokens_each=8192, source_token_counts=[row['sourceTokenCount'] for row in details],
                      native_model_executed=False)))
