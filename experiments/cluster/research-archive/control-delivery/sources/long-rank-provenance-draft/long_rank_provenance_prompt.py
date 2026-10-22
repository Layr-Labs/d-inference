"""Exact pinned origin/raw prompt; neither tokenizer nor launcher is executed."""
import hashlib
from pathlib import Path
from long_reference_provenance_common import files, parse, raw, require, valid_hash


def prompt_bytes(run, receipt, pins, origin_directory):
    origin_directory = Path(origin_directory).resolve(strict=True)
    origin = raw(run / 'inputs/prompt-origin.json', 2 * 1024**2)
    prompt = raw(run / 'inputs/prompt.json', 65536)
    require(hashlib.sha256(origin).hexdigest() == pins.origin
            and hashlib.sha256(prompt).hexdigest() == pins.prompt, 'Explicit raw prompt/origin pin differs')
    require(origin == raw(origin_directory / 'tokenization.json', 2 * 1024**2)
            and prompt == raw(origin_directory / 'prompt-8192.json', 65536)
            == raw(run / 'remote-metadata/rank-0-prompt.json', 65536)
            == raw(run / 'remote-metadata/rank-1-prompt.json', 65536), 'Raw prompt was rewritten or origin differs')
    values = parse(prompt)
    require(type(values) is list and len(values) == 8192
            and all(type(x) is int and 0 <= x < 248320 for x in values), 'Prompt geometry/type differs')
    # Reject number lexemes that parse to integer-like values, including -0.
    import json
    def invalid(value): raise ValueError('Prompt requires strict integer lexemes')
    def integer(value): require(value != '-0', 'Negative zero prompt'); return int(value)
    require(json.loads(prompt, parse_float=invalid, parse_constant=invalid, parse_int=integer) == values,
            'Prompt integer lexemes differ')
    logical = hashlib.sha256(','.join(map(str, values)).encode()).hexdigest()
    inputs = receipt['inputs']
    require(inputs['prompt'] == values and all(type(x) is int for x in inputs['prompt']) and inputs['teacher'] == []
            and inputs['prompt_file_sha256'] == pins.prompt and inputs['prompt_origin_file_sha256'] == pins.origin
            and inputs['prompt_token_ids_sha256'] == logical and inputs['raw_prompt_reencoded'] is False
            and inputs['prompt_origin_schema_audited_by_launcher'] is False, 'Launcher input declarations differ')
    tokenization = parse(origin)
    require(tokenization['kind'] == 'long_prefill_prose_input' and type(tokenization['schemaVersion']) is int
            and tokenization['schemaVersion'] == 1 and tokenization['promptCount'] == 8192
            and type(tokenization['promptCount']) is int and tokenization['vocabularySize'] == 248320
            and type(tokenization['vocabularySize']) is int and tokenization['promptTokenIDsSHA256'] == logical
            and tokenization['addSpecialTokens'] is False and tokenization['chatTemplateApplied'] is False
            and tokenization['representativeWorkloadClaim'] is False and tokenization['modelInferencePerformed'] is False,
            'Pinned tokenization declaration differs')
    source_files = tokenization['files']
    require(set(source_files) == {'prompt-8192.json', 'source-text.txt', 'decoded-prefix.txt', 'preparation.py'},
            'Unexpected origin source inventory')
    inventory = [dict(path=name, size_bytes=value['byteCount'], sha256=value['sha256'])
                 for name, value in source_files.items()]
    verified = files(origin_directory, inventory)
    require(verified['prompt-8192.json'] == pins.prompt, 'Origin prompt declaration differs')
    valid_hash(tokenization['tokenizerJSONSHA256'])
    return dict(rawPromptSHA256=pins.prompt, rawPromptBytes=len(prompt), originSHA256=pins.origin,
                logicalTokenIDsSHA256=logical, originSourceFiles=verified,
                tokenizerJSONSHA256=tokenization['tokenizerJSONSHA256'],
                exactRawOriginLocalAndRemotePromptBytes=True, tokenizerExecuted=False,
                tokenizationSemanticsIndependentlyReproduced=False)
