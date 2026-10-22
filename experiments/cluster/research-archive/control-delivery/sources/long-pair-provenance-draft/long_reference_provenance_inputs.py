"""Exact raw prompt/origin and source metadata declarations; no retokenization."""
import hashlib
from pathlib import Path
from long_reference_provenance_common import files, parse, raw, read, require, sha, valid_hash
from long_reference_provenance_records import ENVIRONMENT, expected_rank


def prompt_bytes(run, receipt, pins, origin_directory):
    origin_directory = Path(origin_directory).resolve(strict=True)
    origin = raw(run / 'inputs/prompt-origin.json', 2 * 1024**2)
    prompt = raw(run / 'inputs/prompt.json', 65536)
    require(hashlib.sha256(origin).hexdigest() == pins.origin
            and hashlib.sha256(prompt).hexdigest() == pins.prompt, 'Explicit raw prompt/origin pin differs')
    require(origin == raw(origin_directory / 'tokenization.json', 2 * 1024**2)
            and prompt == raw(origin_directory / 'prompt-8192.json', 65536)
            == raw(run / 'remote-metadata/prompt.final.json', 65536), 'Raw prompt was rewritten or origin differs')
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


def workload_and_controls(run, receipt, pins, bundle, origin_directory):
    inputs = prompt_bytes(run, receipt, pins, origin_directory)
    rank = read(run / 'native/rank.json')
    require(rank == read(run / 'remote-metadata/rank.final.json') == expected_rank(receipt, pins)
            and sha(run / 'native/rank.json') == sha(run / 'remote-metadata/rank.final.json')
            == receipt['rank_configuration_sha256'], 'Exact native configuration differs')
    remote = receipt['remote_paths']; config = read(run / 'controls/control-config.json')
    require(config == dict(remote, run_id=receipt['run_id'], bundle_sha256=receipt['bundle_manifest_sha256'],
        binary_sha256=pins.native, rank_sha256=receipt['rank_configuration_sha256'], artifact_sha256=pins.artifact,
        configuration_sha256=pins.configuration, prompt_sha256=pins.prompt, prompt_size_bytes=inputs['rawPromptBytes'],
        required_environment=dict(ENVIRONMENT)), 'Pinned control configuration differs')
    for phase in ('before', 'after'):
        record = receipt['remote_' + phase]
        require(record['artifact_aggregate_sha256'] == pins.artifact
                and record['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256']
                and record['bundle_file_sha256'] == bundle
                and record['rank_configuration_sha256'] == receipt['rank_configuration_sha256']
                and record['prompt_sha256'] == pins.prompt and record['prompt_size_bytes'] == inputs['rawPromptBytes']
                and type(record['prompt_size_bytes']) is int and record['raw_prompt_reencoded'] is False,
                'Remote source/input verification attestation differs')
        for name in ('config.json', 'manifest.json'):
            item, local = record['model_metadata'][name], run / 'remote-metadata' / (phase + '-' + name)
            require(item['sha256'] == sha(local) and item['size_bytes'] == local.stat().st_size
                    and type(item['size_bytes']) is int and 0 < item['size_bytes'] <= 1024**2
                    and item['remote_path'] == remote['run'] + '/metadata/' + phase + '-' + name,
                    'Copied remote metadata attestation differs')
    for name in ('config.json', 'manifest.json'):
        require(raw(run / 'remote-metadata' / ('before-' + name), 1024**2)
                == raw(run / 'remote-metadata' / ('after-' + name), 1024**2), 'Remote model metadata changed')
    require(sha(run / 'remote-metadata/before-config.json') == pins.configuration, 'Remote model config pin differs')
    manifest = read(run / 'remote-metadata/before-manifest.json')
    listed = manifest['files']; require(type(listed) is list and 1 <= len(listed) <= 128, 'Unbounded model declaration')
    from long_reference_provenance_common import safe_relative
    declared = {}
    for entry in listed:
        safe_relative(entry['path']); valid_hash(entry['sha256'])
        require(entry['path'] not in declared and type(entry['size_bytes']) is int
                and 0 <= entry['size_bytes'] <= 8 * 1024**3, 'Invalid duplicate model declaration')
        declared[entry['path']] = entry
    total = sum(entry['size_bytes'] for entry in declared.values())
    aggregate = hashlib.sha256(b''.join(bytes.fromhex(declared[name]['sha256']) for name in sorted(declared))).hexdigest()
    require(type(manifest['file_count']) is int and len(declared) == manifest['file_count']
            and type(manifest['total_size_bytes']) is int and total == manifest['total_size_bytes'] <= 8 * 1024**3
            and aggregate == manifest['aggregate_sha256'] == pins.artifact
            and declared['tokenizer.json']['sha256'] == inputs['tokenizerJSONSHA256'], 'Artifact declaration aggregate differs')
    stdout = raw(run / 'native/stdout.jsonl', 8 * 1024**2)
    require(stdout.endswith(b'\n') and len(stdout.splitlines()) == 2
            and all(stdout.splitlines()), 'Expected exactly two complete opaque native records')
    return dict(inputs, exactNativeConfigurationVerified=True, nativeOutputFramingRecords=2,
        nativeOutputJSONParsed=False, stdoutSHA256=hashlib.sha256(stdout).hexdigest(),
        numericalResultIndependentlyVerified=False, declaredArtifactPayloadBytes=total,
        remoteFullArtifactBeforeAfterAttestationsMatch=True, modelPayloadIndependentlyRehashed=False)
