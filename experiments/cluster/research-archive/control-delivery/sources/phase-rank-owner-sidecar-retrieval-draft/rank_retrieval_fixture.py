"""Generated histories and frozen launcher's fabricated native records; no candidate reads."""
import ast
import hashlib
import re
import json
from pathlib import Path, PurePosixPath
import sys

from sidecar_files import sha

UPSTREAM = Path(__file__).parent.parent / 'remote-long-rank-owner-launcher-draft'
assert sha((UPSTREAM / 'source-review-20260914.json').read_bytes()) == '09afb38e895269f3ea9b0a2612111dd672bb97f98b1d5b334bc361fd4085f52d'
for entry in json.loads((UPSTREAM / 'source-review-20260914.json').read_bytes())['files']:
    if entry['path'].endswith('.py'):
        raw = (UPSTREAM / entry['path']).read_bytes()
        assert sha(raw) == entry['sha256'] and len(raw) == entry['size_bytes']
sys.path.insert(0, str(UPSTREAM))
try:
    from long_rank_configuration import configuration as upstream_configuration
    from long_rank_test_support import EPOCH, ENDPOINTS, INPUTS, RAW_PROMPT, fixtures
    from long_rank_warning import WARNING
    from long_reference_inputs import ARTIFACT, CONFIGURATION
finally:
    sys.path.pop(0)


def encoded(value):
    return (json.dumps(value, sort_keys=True) + '\n').encode()


def reseal(run, receipt):
    entries = []
    for rank in (0, 1):
        for name in ('rank.json', 'prompt.json', 'hosts.json', 'stdout.jsonl', 'stderr.log'):
            relative = 'rank-' + str(rank) + '/' + name
            raw = (run / relative).read_bytes()
            entries.append(dict(path=relative, rank=rank, size_bytes=len(raw), sha256=sha(raw),
                                hash_omitted_because_oversized=False))
    receipt['rank_files'] = entries
    receipt['rank_configuration_sha256'] = [sha((run / ('rank-' + str(rank)) / 'rank.json').read_bytes()) for rank in (0, 1)]
    raw = encoded(receipt)
    (run / 'receipt.json').write_bytes(raw)
    return sha(raw)


def frozen_layout(epoch):
    raw = (UPSTREAM / 'long_rank_paths.py').read_bytes()
    assert sha(raw) == 'ca1b6cd8dc9ecd34c3ca41f5ee6f9aeb26b7efd38b2e6630a4da69d994cc36fe'
    nodes = [node for node in ast.parse(raw).body if isinstance(node, ast.FunctionDef)
             and node.name in ('absolute_path', 'paths')]
    assert len(nodes) == 2
    scope = dict(re=re, PurePosixPath=PurePosixPath)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), '<frozen-rank-path-constructor>', 'exec'), scope)
    return scope['paths']('/home/generated', '/tmp/owned-test', '/models/generated-fixture', epoch)


def make_run(folder, policy='serial_v1'):
    run = Path(folder) / 'run'
    run.mkdir()
    (run / 'bundle').mkdir()
    (run / 'bundle/bundle.json').write_bytes(b'{}\n')
    bundle_pin = sha(b'{}\n')
    layout = frozen_layout(EPOCH)
    for rank in (0, 1):
        directory = run / ('rank-' + str(rank))
        directory.mkdir()
        config = upstream_configuration(layout['bundle'], bundle_pin, layout['model'], INPUTS['prompt_file_sha256'], rank, EPOCH, policy)
        (directory / 'rank.json').write_bytes(encoded(config))
        (directory / 'prompt.json').write_bytes(RAW_PROMPT)
        (directory / 'hosts.json').write_bytes(json.dumps(ENDPOINTS).encode())
        (directory / 'stdout.jsonl').write_bytes(b''.join(encoded(row) for row in fixtures(rank, policy)))
        (directory / 'stderr.log').write_bytes(WARNING)
    source = run / 'source/experiments/cluster/inference/Sources/ClusterInference'
    source.mkdir(parents=True)
    literal = 'log("' + WARNING.decode().rstrip('\n') + '")'
    (source / 'Collective.swift').write_text('if transport == .loopbackTest {\n            ' + literal + '\n}')
    (source / 'Options.swift').write_text('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}')
    source_manifest = dict(files=[dict(path=str(path.relative_to(run / 'source')), sha256=sha(path.read_bytes()),
                                      size_bytes=path.stat().st_size) for path in sorted(source.iterdir())])
    source_raw = encoded(source_manifest)
    (run / 'source-manifest.json').write_bytes(source_raw)
    (run / 'launcher').mkdir()
    launchers = []
    for name in ('launch_remote_long_ranks.py', 'long_rank_configuration.py', 'long_rank_paths.py'):
        raw = (UPSTREAM / name).read_bytes()
        (run / 'launcher' / name).write_bytes(raw)
        launchers.append(dict(path=name, sha256=sha(raw), size_bytes=len(raw)))
    receipt = dict(kind='remote_qwen_long_prefill_rank_owner_launcher', schema_version=1,
        native_rank_count=2, transport='loopback-test', backend='ring', flow='profiled_prefill_measurement_v1',
        envelope_version=4, stage_logits_dtype='bfloat16', stage_prefill_policy=policy,
        passed=True, phase_timing_requested=True, owner_timing_requested=True, stage_model_forward_requested=True, timing_requested=True,
        timing_diagnostic_only=True, native_execution_attempted=True,
        source_bundle_raw_inputs_and_remote_model_unchanged_after_run=True,
        primary_failure=None, cleanup_errors=[], post_run_errors=[],
        cohort=dict(passed=True, cancellation_reason=None, error=None, cleanup_errors=[], exit_codes=[0, 0],
                    local_ssh_client_pids=[1234, 1235], local_ssh_clients_reaped=[True, True],
                    validation=dict(records_per_rank=[2, 2], shared_agreement_matches=True)),
        execution_host='example-test-host', epoch=EPOCH, run_id=EPOCH, remote_paths=layout,
        source_manifest_sha256=sha(source_raw), bundle_manifest_sha256=bundle_pin,
        launcher_files=launchers, expected_native_sha256='d' * 64,
        artifact_aggregate_sha256=ARTIFACT, configuration_sha256=CONFIGURATION,
        inputs=dict(INPUTS), hostfile=ENDPOINTS,
        stderr_contract=dict(expected_utf8=WARNING.decode(), exact_one_line_required=True,
                             source_sha256={p.name: sha(p.read_bytes()) for p in source.iterdir()}))
    return run, receipt, reseal(run, receipt)


def response(context):
    trace = dict(kind='qwen_prefill_local_phase_trace', schemaVersion=1, identity=context['expected_identity'],
        clockSource='DispatchTime.uptimeNanoseconds', maximumEvents=512,
        events=[dict(ordinal=0, phase='fixture', committedTokens=0, localUptimeNanoseconds=100)],
        firstLocalUptimeNanoseconds=100, lastLocalUptimeNanoseconds=100, traceSpanNanoseconds=0,
        diagnosticOnly=True, includesRecorderOverhead=True, crossProcessClockAlignmentAsserted=False,
        gpuOverlapAsserted=False, modelReleaseAsserted=False, recorderIndependentlyVerifiesRequestRetirement=False)
    if context['name'] == 'owner':
        trace.update(kind='qwen_prefill_selected_owner_trace', maximumEvents=8,
            events=[dict(ordinal=i, phase='synthetic-opaque', tokenCount=512, committedTokens=4096,
                         localUptimeNanoseconds=100+i) for i in range(8)],
            evaluationIntervalIncludesExistingErrorCheck=True, gpuKernelTimeAsserted=False,
            recorderIndependentlyVerifiesOuterSuccess=False)
        del trace['recorderIndependentlyVerifiesRequestRetirement']
    raw = encoded(trace)
    metadata = dict(kind='qwen_prefill_phase_sidecar_read', schema_version=1, path=context['remote_path'],
        sha256=sha(raw), size_bytes=len(raw), mode=0o600, uid=501, gid=20, device=1, inode=2,
        link_count=1, mtime_ns=10, ctime_ns=11, stable_descriptor_read=True,
        followed_symlinks=False, remote_file_modified=False)
    return metadata, raw
