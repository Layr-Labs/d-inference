"""Fabricated archive/pipe fixtures only; no candidate inputs or network calls."""
import ast
import json
from pathlib import Path
from types import SimpleNamespace
from sidecar_files import sha


def encoded(value):
    return (json.dumps(value, sort_keys=True) + '\n').encode()


FROZEN = Path(__file__).resolve().parent.parent / 'remote-long-solo-owner-launcher-draft'
PINS = {'launch_remote_long_solo.py': '04ea975234e7abd3b71b35ca9f9cca74f8d65a63110afe2b5638301446475f83',
        'long_reference_configuration.py': '545f1cad8e1821598e8a3872274cf1e3b1576b5a76f4cda3061e1c42e37865bb'}


def frozen_source(name):
    raw = (FROZEN / name).read_bytes()
    assert sha(raw) == PINS[name]
    return raw


def frozen_configuration(layout, bundle_hash, prompt_hash):
    # Only the frozen pure configuration function is evaluated; no launcher import or process APIs.
    tree = ast.parse(frozen_source('long_reference_configuration.py'))
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'configuration')
    def require(value, message):
        if not value:
            raise ValueError(message)
    namespace = dict(require=require, is_sha256=lambda value: type(value) is str and len(value) == 64,
        ARTIFACT='127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
        NATIVE_TIMEOUT_SECONDS=300, REQUIRED_ENVIRONMENT={'DARKBLOOM_BF16_WEIGHTS': '1',
            'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'})
    exec(compile(ast.Module(body=[function], type_ignores=[]), '<frozen-pure-configuration>', 'exec'), namespace)
    return namespace['configuration'](layout['bundle'], bundle_hash, layout['model'], prompt_hash)


def make_run(directory):
    run = Path(directory) / 'run'
    run.mkdir()
    for name in ('native', 'launcher', 'bundle'):
        (run / name).mkdir()
    fingerprint = 'c' * 64
    first = dict(kind='qwen_long_prefill_solo_ready', schemaVersion=1,
                 recordedRequestFingerprint=fingerprint, profile='long_prefill_8k_v1')
    final = dict(kind='qwen_long_prefill_solo_report', schemaVersion=1, completed=True,
        allRequestStateRetired=True, modelReleased=True, profile=first['profile'],
        execution=dict(request=dict(fingerprint=fingerprint)))
    run_id = 'a' * 32
    layout = dict(root='/tmp/owned-test', run='/tmp/owned-test/' + run_id,
                  native='/tmp/owned-test/' + run_id + '/native',
                  bundle='/tmp/owned-test/' + run_id + '/bundle', model='/tmp/model-fixture')
    rank = frozen_configuration(layout, sha(b'{}\n'), 'e' * 64)
    entries = []
    for name, raw in [('rank.json', encoded(rank)), ('stdout.jsonl', encoded(first) + encoded(final)),
                      ('stderr.log', b'')]:
        (run / 'native' / name).write_bytes(raw)
        entries.append(dict(path='native/' + name, sha256=sha(raw), size_bytes=len(raw),
                            hash_omitted_because_oversized=False))
    launchers = []
    for name in ('launch_remote_long_solo.py', 'long_reference_configuration.py'):
        raw = frozen_source(name)
        (run / 'launcher' / name).write_bytes(raw)
        launchers.append(dict(path=name, sha256=sha(raw), size_bytes=len(raw)))
    for name in ('source-manifest.json', 'bundle/bundle.json'):
        (run / name).write_bytes(b'{}\n')
    run_id = 'a' * 32
    receipt = dict(kind='remote_qwen_long_prefill_solo_owner_launcher', schema_version=1,
        passed=True, phase_timing_requested=True, owner_timing_requested=True, full_solo_forward_requested=True,
        timing_requested=True, timing_diagnostic_only=True, native_execution_attempted=True,
        source_bundle_raw_inputs_and_remote_model_unchanged_after_run=True,
        primary_failure=None, cleanup_errors=[], post_run_errors=[],
        execution=dict(passed=True, local_ssh_client_reaped=True, local_ssh_client_pid=1234,
                       exit_code=0, cancellation_reason=None, error=None, cleanup_errors=[], validated_outer_records=2),
        execution_host='example-test-host', run_id=run_id,
        remote_paths=layout, inputs=dict(prompt_file_sha256='e' * 64),
        native_files=entries, launcher_files=launchers,
        rank_configuration_sha256=sha(encoded(rank)), source_manifest_sha256=sha(b'{}\n'),
        bundle_manifest_sha256=sha(b'{}\n'), expected_native_sha256='d' * 64)
    raw = encoded(receipt)
    (run / 'receipt.json').write_bytes(raw)
    return run, receipt, sha(raw)


def make_response(context):
    trace = dict(kind='qwen_prefill_local_phase_trace', schemaVersion=1,
        identity=context['expected_identity'], clockSource='DispatchTime.uptimeNanoseconds',
        maximumEvents=512, events=[dict(ordinal=0, phase='fixture', committedTokens=0,
                                       localUptimeNanoseconds=100)],
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
    metadata = dict(kind='qwen_prefill_phase_sidecar_read', schema_version=1,
        path=context['remote_path'], sha256=sha(raw), size_bytes=len(raw), mode=0o600,
        uid=501, gid=20, device=1, inode=2, link_count=1, mtime_ns=10, ctime_ns=11,
        stable_descriptor_read=True, followed_symlinks=False, remote_file_modified=False)
    return metadata, raw


def response_bytes(metadata, raw):
    return encoded(metadata) + raw

