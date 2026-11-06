"""Fabricated archive/pipe fixtures only; no candidate inputs or network calls."""
import json
from pathlib import Path
from types import SimpleNamespace
from sidecar_files import sha


def encoded(value):
    return (json.dumps(value, sort_keys=True) + '\n').encode()


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
    rank = dict(arguments=['--mode', 'qwen-long-prefill-solo-check',
                          '--prefill-phase-trace-file', '@rank/phase-trace.json'])
    entries = []
    for name, raw in [('rank.json', encoded(rank)), ('stdout.jsonl', encoded(first) + encoded(final)),
                      ('stderr.log', b'')]:
        (run / 'native' / name).write_bytes(raw)
        entries.append(dict(path='native/' + name, sha256=sha(raw), size_bytes=len(raw),
                            hash_omitted_because_oversized=False))
    launchers = []
    for name in ('launch_remote_long_solo.py', 'long_reference_configuration.py'):
        raw = b'# explicitly fabricated archive source\n'
        (run / 'launcher' / name).write_bytes(raw)
        launchers.append(dict(path=name, sha256=sha(raw), size_bytes=len(raw)))
    for name in ('source-manifest.json', 'bundle/bundle.json'):
        (run / name).write_bytes(b'{}\n')
    run_id = 'a' * 32
    receipt = dict(kind='remote_qwen_long_prefill_solo_phase_launcher', schema_version=1,
        passed=True, phase_timing_requested=True, full_solo_forward_requested=True,
        timing_requested=True, timing_diagnostic_only=True, native_execution_attempted=True,
        source_bundle_raw_inputs_and_remote_model_unchanged_after_run=True,
        primary_failure=None, cleanup_errors=[], post_run_errors=[],
        execution=dict(passed=True, local_ssh_client_reaped=True, local_ssh_client_pid=1234,
                       exit_code=0, cancellation_reason=None, error=None, cleanup_errors=[], validated_outer_records=2),
        execution_host='example-test-host', run_id=run_id,
        remote_paths=dict(root='/tmp/owned-test', run='/tmp/owned-test/' + run_id,
                          native='/tmp/owned-test/' + run_id + '/native'),
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
    raw = encoded(trace)
    metadata = dict(kind='qwen_prefill_phase_sidecar_read', schema_version=1,
        path=context['remote_path'], sha256=sha(raw), size_bytes=len(raw), mode=0o600,
        uid=501, gid=20, device=1, inode=2, link_count=1, mtime_ns=10, ctime_ns=11,
        stable_descriptor_read=True, followed_symlinks=False, remote_file_modified=False)
    return metadata, raw


def response_bytes(metadata, raw):
    return encoded(metadata) + raw


class FakeStream:
    def __init__(self, number, raw):
        self.number, self.data, self.closed = number, bytearray(raw), False
    def fileno(self):
        return self.number
    def close(self):
        self.closed = True


class FakeChild:
    def __init__(self, stdout=b'fixture', stderr=b'', code=0):
        self.stdout, self.stderr = FakeStream(21, stdout), FakeStream(22, stderr)
        self.pid, self.returncode, self.code, self.waits = 99123, None, code, 0
    def poll(self):
        return self.returncode
    def wait(self, timeout):
        self.waits += 1
        self.returncode = self.code
        return self.code
    def read(self, descriptor, count):
        stream = self.stdout if descriptor == 21 else self.stderr
        raw = bytes(stream.data[:count])
        del stream.data[:count]
        return raw


class FakeSelector:
    def __init__(self):
        self.keys, self.closed = {}, False
    def register(self, fileobj, events, data):
        self.keys[fileobj] = SimpleNamespace(fileobj=fileobj, data=data)
    def unregister(self, fileobj):
        del self.keys[fileobj]
    def get_map(self):
        return self.keys
    def select(self, timeout):
        return [(key, 1) for key in list(self.keys.values())]
    def close(self):
        self.closed = True
