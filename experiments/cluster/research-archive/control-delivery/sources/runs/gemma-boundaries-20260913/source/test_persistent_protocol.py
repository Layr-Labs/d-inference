"""CPU-only protocol boundaries and bounded pipe framing for persistent workers."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from runtime import persistent_protocol as protocol
from runtime import persistent_io
from runtime.persistent import PersistentCohort, PersistentCohortError
from persistent_test_support import PersistentFixture, cohort_spec
from test_runtime_reports import make_report, make_spec


EPOCH = '1' * 32


def ready_fixture(spec=None, rank=0):
    spec = spec or make_spec()
    report = make_report(spec, rank)
    identity = {key: report.get(key, 'none') for key in ('model', 'modelFamily', 'configurationSHA256',
        'partition', 'attentionOutputPrecision', 'ffnBranchPrecision', 'vocabularySize', 'feedForwardKind',
        'embeddingActivationDType', 'ffnScaleDTypes', 'syntheticWeights', 'syntheticDType',
        'syntheticProfile', 'bf16ConversionEnabled', 'transport', 'tokenSelectionPolicy', 'mtpEnabled')}
    identity.update(partitionPlanSHA256=report.get('partitionPlanSHA256', 'none'), layerCount=4,
                    verifiedAggregateSHA256=spec.get('artifact_aggregate_sha256', 'none')
                        if report['worldSize'] == 2 else 'none', seed='7', textOnly=True,
                    parameterLayoutSHA256s=[report['parameterLayoutSHA256']], partitionStorageSHA256='none')
    if 'partitionStorage' in report:
        identity.update(parameterLayoutSHA256s=[item['parameterLayoutSHA256'] for item in report['partitionStorage']['ranks']],
                        partitionStorageSHA256=protocol.hash_frame(report['partitionStorage']))
    ready = dict(version=3, type='ready', epoch=EPOCH, rank=rank, worldSize=report['worldSize'], pid=123,
                 parameterLayoutSHA256=report['parameterLayoutSHA256'],
                 modelLoadID='fixture-load-1', modelLoadCount=1, identity=identity,
                 identitySHA256=protocol.hash_frame(identity),
                 limits={**protocol.LIMITS, 'maxContextTokens': 8192, 'idleTimeoutSeconds': spec['timeout_seconds']})
    if 'partitionStorage' in report:
        ready['partitionStorage'] = report['partitionStorage']
    return spec, ready


class PersistentProtocolTests(unittest.TestCase):
    def command(self, ready=None, **changes):
        if ready is None:
            _, ready = ready_fixture()
        args = dict(epoch=EPOCH, sequence=1, request_id='r-1', prompt=[3, 9, 14, 18],
                    output_tokens=3, chunk_size=3, teacher_tokens=None, capture_logits=False,
                    timeout_seconds=10, ready_record=ready)
        args.update(changes)
        return protocol.request(**args)

    def test_canonical_hash_keeps_unicode_and_slashes_and_omits_absent_teacher(self):
        self.assertEqual(persistent_io.canonical({'z': '/', 'a': 'é'}), b'{"a":"\xc3\xa9","z":"/"}')
        command = self.command()
        self.assertNotIn('teacherTokens', command)
        self.assertNotEqual(protocol.hash_frame(command), protocol.hash_frame({**command, 'teacherTokens': None}))
        self.assertEqual(self.command(teacher_tokens=[17, 18])['teacherTokens'], [17, 18])

    def test_ready_is_closed_and_identity_hash_and_limits_are_checked(self):
        spec, good = ready_fixture()
        protocol.ready(good, EPOCH, 0, spec)
        for field, value in [('unknown', 1), ('version', True), ('rank', True), ('worldSize', 2),
                             ('modelLoadCount', 2), ('pid', 0), ('identitySHA256', 'f' * 64)]:
            bad = copy.deepcopy(good); bad[field] = value
            with self.subTest(field=field), self.assertRaises(PersistentCohortError):
                protocol.ready(bad, EPOCH, 0, spec)
        for field in good:
            bad = copy.deepcopy(good); del bad[field]
            with self.subTest(missing=field), self.assertRaises(PersistentCohortError):
                protocol.ready(bad, EPOCH, 0, spec)
        for field, value in [('attentionOutputPrecision', 'float32'), ('textOnly', False),
                             ('syntheticDType', 'bfloat16'), ('verifiedAggregateSHA256', 'b' * 64)]:
            bad = copy.deepcopy(good); bad['identity'][field] = value
            bad['identitySHA256'] = protocol.hash_frame(bad['identity'])
            with self.subTest(identity=field), self.assertRaises(PersistentCohortError):
                protocol.ready(bad, EPOCH, 0, spec)
        bad = copy.deepcopy(good); bad['limits']['maxRequestsPerEpoch'] += 1
        with self.assertRaises(PersistentCohortError): protocol.ready(bad, EPOCH, 0, spec)

    def test_context_reserves_every_output_token_including_first(self):
        _, ready = ready_fixture(); ready['limits']['maxContextTokens'] = 8
        self.command(ready, prompt=[3] * 5, output_tokens=3)
        with self.assertRaisesRegex(ValueError, 'context'):
            self.command(ready, prompt=[3] * 6, output_tokens=3)
        self.command(ready, prompt=[3] * 7, output_tokens=1)
        with self.assertRaisesRegex(ValueError, 'context'):
            self.command(ready, prompt=[3] * 8, output_tokens=1)

    def test_request_bounds_fail_before_dispatch(self):
        for key, values in dict(request_id=['', 'space id', 'é', 'a' * 129], prompt=[[], [True], [-1], [512]],
            output_tokens=[0, True, 4097], chunk_size=[0, 32769], timeout_seconds=[0, 301, .5],
            sequence=[0, 4097], capture_logits=[1, None], teacher_tokens=[[], [3], [3, True]]).items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    self.command(**{key: value})
        with self.assertRaisesRegex(ValueError, 'Logit capture'):
            self.command(output_tokens=2049, capture_logits=True)
        _, ready = ready_fixture(); ready['limits']['maxLineBytes'] = 50
        with self.assertRaisesRegex(ValueError, 'line limit'):
            self.command(ready)

    def test_completed_identity_result_history_and_capture_are_bound(self):
        spec, ready = ready_fixture(); command = self.command()
        result = make_report(spec)['runs'][0]; result['iteration'] = 1
        good = dict(version=3, type='completed', epoch=EPOCH, rank=0, sequence=1, requestID='r-1',
                    requestSHA256=protocol.hash_frame(command), modelLoadID=ready['modelLoadID'], result=result)
        protocol.completed(good, command, ready, 0, [0, 1, 2])
        for field, value in [('epoch', '2' * 32), ('requestSHA256', 'f' * 64), ('modelLoadID', 'other'), ('sequence', 0)]:
            bad = copy.deepcopy(good); bad[field] = value
            with self.subTest(field=field), self.assertRaises(PersistentCohortError):
                protocol.completed(bad, command, ready, 0, [0, 1, 2])
        bad = copy.deepcopy(good); bad['result']['decodeInputTokens'] = [9, 8]
        with self.assertRaises(PersistentCohortError): protocol.completed(bad, command, ready, 0, [0, 1, 2])
        bad = copy.deepcopy(good); bad['logits'] = []
        with self.assertRaises(PersistentCohortError): protocol.completed(bad, command, ready, 0, [0, 1, 2])

    def test_duplicate_id_and_bad_local_request_preserve_reusable_epoch(self):
        fixture = PersistentFixture()
        self.addCleanup(fixture.cleanup)
        spec = cohort_spec(); spec['backend'] = 'solo'; spec['ranks'] = spec['ranks'][:1]
        cohort = PersistentCohort(spec, fixture.source, fixture.output)
        self.addCleanup(cohort.close)
        cohort.start(); epoch = cohort.epoch
        cohort.infer('first', [3, 4], 2, 2)
        for args in [('first', [3, 4], 2, 2), ('invalid', [512], 2, 2)]:
            with self.assertRaises(ValueError): cohort.infer(*args)
            self.assertEqual(cohort.state, 'idle'); self.assertEqual(cohort.epoch, epoch)
        completed = cohort.infer('second', [9, 10], 2, 2)
        self.assertEqual(completed[0]['sequence'], 2)
        cohort.close(); fixture.assert_stopped()

    def test_persistent_supervisor_flag_rejects_non_boolean_before_start(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'rank.json'
            path.write_text(json.dumps({'persistent': 'true'}))
            worker = Path(__file__).parent / 'runtime/rank_worker.py'
            run = subprocess.run([sys.executable, str(worker), str(path)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 1)
            self.assertIn('persistent must be a boolean', run.stderr)


class PersistentPipeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        stdout_read, self.writer = os.pipe()
        self.reader, stdin_write = os.pipe()
        self.addCleanup(os.close, self.writer)
        self.addCleanup(os.close, self.reader)
        process = SimpleNamespace(stdout=os.fdopen(stdout_read, 'rb', buffering=0),
                                  stdin=os.fdopen(stdin_write, 'wb', buffering=0), poll=lambda: None)
        self.io = persistent_io.FrameIO([process], [self.temporary.name], threading.Event())
        self.addCleanup(self.io.close)

    def deadline(self): return time.monotonic() + 1

    def test_split_json_line_and_already_exited_writer_are_drained(self):
        os.write(self.writer, b'{"type":')
        self.io.pump(self.deadline())
        self.assertFalse(self.io.frames[0])
        self.io.processes[0].poll = lambda: 0
        os.write(self.writer, b'"stopped"}\n')
        self.assertEqual(self.io.receive(0, self.deadline()), {'type': 'stopped'})

    def test_malformed_duplicate_empty_and_nonfinite_frames_fail_closed(self):
        for payload in (b'{}bad\n', b'{"a":1,"a":2}\n', b'\n', b'{"a":NaN}\n', b'[]\n', b'\xff\n'):
            self.io.buffers[0].clear(); self.io.scan_from[0] = 0
            os.write(self.writer, payload)
            with self.subTest(payload=payload), self.assertRaises(PersistentCohortError):
                self.io.pump(self.deadline())

    def test_line_and_aggregate_byte_caps_are_independent(self):
        with patch.object(persistent_io, 'MAX_FRAME_BYTES', 16):
            os.write(self.writer, b'x' * 17)
            with self.assertRaisesRegex(PersistentCohortError, 'byte limit'): self.io.pump(self.deadline())
        self.io.buffers[0].clear(); self.io.scan_from[0] = 0
        with patch.object(persistent_io, 'MAX_QUEUED_BYTES', 10):
            os.write(self.writer, b'{"a":1}\n{"a":2}\n')
            with self.assertRaisesRegex(PersistentCohortError, 'aggregate'): self.io.pump(self.deadline())

    def test_queue_backpressure_resumes_without_dropping_frames(self):
        with patch.object(persistent_io, 'MAX_QUEUED_FRAMES', 2):
            os.write(self.writer, b'{"n":1}\n{"n":2}\n{"n":3}\n')
            self.io.pump(self.deadline())
            self.assertTrue(self.io.paused[0])
            self.assertEqual([self.io.receive(0, self.deadline())['n'] for _ in range(3)], [1, 2, 3])
            self.assertFalse(self.io.paused[0]); self.assertEqual(self.io.queued_bytes, 0)

    def test_idle_observation_has_no_request_deadline_to_expire(self):
        with patch.object(persistent_io.time, 'monotonic', side_effect=AssertionError('Idle poll used a deadline')):
            self.io.pump(None, poll_timeout=0)


class PersistentReceiptTests(unittest.TestCase):
    def test_fencing_marks_the_active_request_failed_in_the_receipt(self):
        fixture = PersistentFixture({'1': 'wrong_hash'})
        self.addCleanup(fixture.cleanup)
        cohort = PersistentCohort(cohort_spec(), fixture.source, fixture.output)
        self.addCleanup(cohort.close)
        cohort.start()
        with self.assertRaises(PersistentCohortError):
            cohort.infer('failed-request', [3, 4], 2, 2)
        fixture.assert_stopped()
        receipt = json.loads((fixture.output / 'session.json').read_text())
        self.assertEqual(receipt['state'], 'failed')
        self.assertEqual(receipt['requests'][-1]['status'], 'failed')
        self.assertIn('requestSHA256', receipt['requests'][-1]['failure'])


if __name__ == '__main__':
    unittest.main()
