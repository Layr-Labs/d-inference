#!/usr/bin/env python3
"""Post-run saved outer-schema replay. Never invokes a launcher or native code."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
from pathlib import Path
import sys
from unittest.mock import patch

MANIFEST_SHA256 = '99abfabda725b16d9b1df0ef0b3b353bff558988920177329854c0829417757f'
CASES = [
    ('qwen-long-prefill-ranks-serial-peer24-20260914', 'long-prefill-ranks', 'serial_v1',
     '4e5b015b619a35e7e261f0bd45c6954406f42eaabd8f9a11da592a44e3e470d9'),
    ('qwen-long-prefill-ranks-lookahead-peer24-20260914', 'long-prefill-ranks', 'prompt_lookahead_one_v1',
     '17de7244b91234a0752c1b673fe61fc8f6584b4cd201933925bc2af6b5772711'),
    ('qwen-long-prefill-solo-peer24-20260914', 'long-prefill-solo', None,
     '4f8f98c9bdfb39d58ac9e1ce1027ecfc86dc6ae322963fe5b9f0e25b30395680')]


def require(value, message):
    if not value: raise ValueError(message)


def read(path, cap):
    require(path.is_file() and path.stat().st_size <= cap, 'File exceeds replay bound: ' + str(path))
    with path.open('rb') as stream: data = stream.read(cap + 1)
    require(len(data) <= cap, 'File grew beyond replay bound')
    return data


def sha(path): return hashlib.sha256(read(path, 16 * 1024**2)).hexdigest()


def replay(run, mode, policy, pin, package):
    common = importlib.import_module(package + '.common')
    inputs_module = importlib.import_module(package + '.long_inputs')
    stream = importlib.import_module(package + '.long_stream')
    rank_contract = importlib.import_module(package + '.long_rank_contract')
    profile = importlib.import_module(package + '.long_profile')
    require(sha(run / 'receipt.json') == pin, 'Frozen launcher receipt differs')
    receipt = common.parse(read(run / 'receipt.json', 4 * 1024**2))
    require(receipt['passed'] is True and receipt['primary_failure'] is None
            and receipt['cleanup_errors'] == [] and receipt['post_run_errors'] == [], 'Original launcher did not complete cleanly')
    paired = mode.endswith('ranks')
    require(receipt['kind'] == ('remote_qwen_long_prefill_rank_launcher' if paired else 'remote_qwen_long_prefill_solo_launcher'),
            'Original launcher namespace differs')
    require(receipt['artifact_aggregate_sha256'] == profile.ARTIFACT
            and receipt['configuration_sha256'] == profile.CONFIGURATION, 'Registered source pins differ')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Stored bundle manifest differs')
    bundle = common.parse(read(run / 'bundle/bundle.json', 1024**2))
    binary = [item for item in bundle['files'] if item['path'] == 'cluster-inference']
    require(len(binary) == 1 and binary[0]['sha256'] == receipt['expected_native_sha256'], 'Native binary declaration differs')
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Original source manifest differs')
    raw = read(run / 'inputs/prompt.json', 65536); prompt = inputs_module.prompt_ids(raw)
    origin = read(run / 'inputs/prompt-origin.json', 2 * 1024**2)
    known = receipt['inputs']
    require(common.digest(raw) == known['prompt_file_sha256'] and prompt == known['prompt'] and known['teacher'] == []
            and common.digest(origin) == known['prompt_origin_file_sha256'] and known['raw_prompt_reencoded'] is False,
            'Retained raw prompt/origin differs')
    logical = common.digest(','.join(map(str, prompt)).encode())
    require(logical == known['prompt_token_ids_sha256'], 'Retained token-ID fingerprint differs')
    context = dict(mode=mode, epoch=receipt['epoch'] if paired else receipt['run_id'], prompt=prompt,
        prompt_file_sha256=common.digest(raw), prompt_token_ids_sha256=logical,
        stage_prefill_policy=policy, stage_logits_dtype='bfloat16' if paired else None)
    if paired:
        require(receipt['stage_prefill_policy'] == policy and receipt['stage_logits_dtype'] == 'bfloat16', 'Saved policy differs')
        require(stream.source_stderr_contract(run, True) == receipt['stderr_contract'], 'Archived warning source differs')
    entries = {item['path']:item for item in receipt['rank_files' if paired else 'native_files']}
    readers, outputs = [], []
    for rank in range(2 if paired else 1):
        directory = run / ('rank-' + str(rank) if paired else 'native')
        for name in ('stdout.jsonl','stderr.log'):
            path = directory / name; item = entries[path.relative_to(run).as_posix()]
            require(item['hash_omitted_because_oversized'] is False and sha(path) == item['sha256']
                    and path.stat().st_size == item['size_bytes'], 'Stored output bytes differ from original receipt')
        reader = stream.Records(directory, rank, context); reader.poll(final=True); readers.append(reader)
        outputs.append(dict(owner=rank, readyKind=reader.rows[0]['kind'], terminalKind=reader.rows[1]['kind'],
            records=len(reader.rows), stdoutSHA256=sha(directory / 'stdout.jsonl'), stderrSHA256=sha(directory / 'stderr.log')))
    if paired: rank_contract.peers(readers)
    require(sha(run / 'receipt.json') == pin, 'Receipt changed during replay')
    return dict(run=run.name, mode=mode, policy=policy, status='passed', launcherReceiptSHA256=pin,
        nativeBinarySHA256=binary[0]['sha256'], originalSourceManifestSHA256=receipt['source_manifest_sha256'],
        bundleManifestSHA256=receipt['bundle_manifest_sha256'], rawPromptSHA256=common.digest(raw),
        rawPromptBytes=len(raw), promptTokenIDsSHA256=logical, promptOriginSHA256=common.digest(origin),
        controllerEpoch=context['epoch'], peerAgreementValidated=paired, owners=outputs,
        publicLauncherExecuted=False, independentNumericalActionWireTimingAuditPerformed=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--draft-manifest', type=Path, required=True)
    parser.add_argument('--runs-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); require(not args.output.exists(), 'Preserve existing replay result')
    require(sha(args.draft_manifest) == MANIFEST_SHA256, 'Frozen public implementation manifest differs')
    manifest = json.loads(read(args.draft_manifest, 1024**2)); files = {}
    for item in manifest['files']:
        path = args.repository / item['intended_repo_path']
        expected = item['result_sha256'] if item['operation'] == 'append' else item['sha256']
        require(sha(path) == expected, 'Integrated public source differs: ' + item['intended_repo_path'])
        files[item['intended_repo_path']] = expected
    for path, expected in manifest['sharedSourceDependencies'].items():
        require(sha(args.repository / path) == expected, 'Shared public dependency differs: ' + path)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(args.repository / 'experiments/cluster'))
    results = []
    with patch('subprocess.Popen', side_effect=AssertionError('Replay cannot start processes')), \
         patch('subprocess.run', side_effect=AssertionError('Replay cannot start processes')), \
         patch('socket.socket', side_effect=AssertionError('Replay cannot create sockets')):
        for name, mode, policy, pin in CASES:
            try: results.append(replay(args.runs_root / name, mode, policy, pin, 'runtime.stage_checks'))
            except Exception as error: results.append(dict(run=name, mode=mode, policy=policy, status='failed',
                launcherReceiptSHA256=pin, error=type(error).__name__ + ': ' + str(error)))
    record = dict(kind='public_long_prefill_saved_schema_replay', schemaVersion=1,
        status='passed' if all(value['status'] == 'passed' for value in results) else 'failed',
        replayScriptSHA256=sha(Path(__file__)), publicDraftManifestSHA256=MANIFEST_SHA256,
        integratedSourceSHA256=files, sharedSourceDependencies=manifest['sharedSourceDependencies'],
        replayedAtUTC=datetime.now(timezone.utc).isoformat(), cases=results,
        publicLauncherExecuted=False, nativeExecutions=0, SSHExecutions=0, compilerExecutions=0,
        modelPayloadBytesRead=0, independentNumericalActionWireTimingAuditPerformed=False,
        validationIsPostRun=True, candidateOutputsPreviouslyCompleted=True,
        limitations=['This calls the integrated public outer validators on existing guarded-run files; it does not execute the public entry.',
            'Native numerical, wire/action, timing and resource/provenance audits remain the separately archived original evidence.',
            'The implementation and test fixture files were neither weakened nor changed for these outputs.'])
    with args.output.open('x') as stream: json.dump(record, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps(dict(status=record['status'], output=str(args.output), sha256=sha(args.output),
                         cases=[dict(run=value['run'], status=value['status']) for value in results])))
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__': sys.exit(main())
