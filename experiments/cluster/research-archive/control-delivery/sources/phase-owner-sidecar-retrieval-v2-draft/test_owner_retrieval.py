import copy
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import owner_sidecar_remote_reader as remote_owner
import phase_sidecar_remote_reader as remote_phase
from owner_retrieval_fixture import encoded, frozen_configuration, frozen_layout, make_run, make_response, response_bytes
from owner_sidecar_admission import admit_run
from owner_sidecar_response import decode_response
from retrieve_owner_sidecars import retrieve
from sidecar_files import MAX_SIDECAR, parse, sha
from sidecar_ssh import SSHReadFailure


class OwnerRetrievalTests(unittest.TestCase):
    def setUp(self):
        self.guards = [patch('subprocess.Popen', side_effect=AssertionError('No processes')),
                       patch('subprocess.run', side_effect=AssertionError('No processes')),
                       patch('socket.socket', side_effect=AssertionError('No sockets'))]
        for guard in self.guards:
            guard.start()
            self.addCleanup(guard.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name).resolve()
        self.run, self.receipt, self.pin = make_run(self.folder)
        self.context = admit_run(self.run, self.pin)
        self.calls = []

    def save(self, receipt):
        raw = encoded(receipt)
        (self.run / 'receipt.json').write_bytes(raw)
        return sha(raw)

    def replace_native(self, name, raw, receipt):
        (self.run / 'native' / name).write_bytes(raw)
        for entry in receipt['native_files']:
            if entry['path'] == 'native/' + name:
                entry.update(sha256=sha(raw), size_bytes=len(raw))
        if name == 'rank.json':
            receipt['rank_configuration_sha256'] = sha(raw)
        return self.save(receipt)

    def fake_reader(self, host, path, payload):
        context = next(item for item in self.context['sidecars'] if item['remote_path'] == path)
        self.assertEqual(host, context['host'])
        self.assertIn("components[-1] == '" + context['name'] + "-trace.json'", payload)
        self.calls.append(context['name'])
        metadata, raw = make_response(context)
        return response_bytes(metadata, raw), b'', dict(local_reader_ssh_client_reaped=True,
            local_reader_ssh_client_pid=888 + len(self.calls), remote_process_reaping_verified=False)

    def test_pair_success_keeps_distinct_exact_raw_mode_and_narrow_claims(self):
        result = retrieve(self.run, self.pin, self.folder / 'out', reader=self.fake_reader)
        self.assertTrue(result['passed'])
        self.assertEqual(self.calls, ['phase', 'owner'])
        for context, record in zip(self.context['sidecars'], result['sidecars']):
            _, raw = make_response(context)
            path = self.folder / 'out' / record['sidecar']['path']
            self.assertEqual(path.read_bytes(), raw)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(record['sidecar']['sha256'], sha(raw))
            self.assertFalse(record['sidecar']['request_correlation']['event_sequence_semantics_audited'])
        self.assertFalse(result['numerical_or_timing_semantics_audited'])
        self.assertFalse(result['remote_process_reaping_verified'])

    def test_namespace_flags_and_failed_source_guard_cannot_be_waived(self):
        mutations = [lambda r: r.update(kind='remote_qwen_long_prefill_solo_phase_launcher'),
            lambda r: r.update(owner_timing_requested=False), lambda r: r.update(phase_timing_requested=False),
            lambda r: r.update(passed=False),
            lambda r: r.update(source_bundle_raw_inputs_and_remote_model_unchanged_after_run=False),
            lambda r: r.update(primary_failure={'error': 'source drift'}),
            lambda r: r.update(cleanup_errors=['failed']), lambda r: r.update(post_run_errors=['failed'])]
        for index, mutate in enumerate(mutations):
            value = copy.deepcopy(self.receipt)
            mutate(value)
            result = retrieve(self.run, self.save(value), self.folder / ('reject-' + str(index)),
                              reader=lambda *args: self.fail('Reader called'))
            self.assertFalse(result['passed'])

    def test_completed_client_and_native_record_types_are_strict(self):
        for key, invalid in [('local_ssh_client_reaped', False), ('local_ssh_client_pid', True),
                             ('validated_outer_records', 2.0), ('exit_code', False), ('error', 'failure')]:
            value = copy.deepcopy(self.receipt)
            value['execution'][key] = invalid
            with self.assertRaises(ValueError):
                admit_run(self.run, self.save(value))
        original = (self.run / 'native/stdout.jsonl').read_bytes()
        for field, invalid in [('schemaVersion', True), ('profile', 'wrong'), ('recordedRequestFingerprint', 'f' * 64)]:
            rows = [parse(raw) for raw in original.splitlines()]
            rows[0][field] = invalid
            changed = b''.join(encoded(row) for row in rows)
            with self.assertRaises(ValueError):
                admit_run(self.run, self.replace_native('stdout.jsonl', changed, copy.deepcopy(self.receipt)))

    def test_exact_frozen_configuration_rejects_missing_duplicate_and_other_changes(self):
        original = parse((self.run / 'native/rank.json').read_bytes())
        mutations = [lambda v: v['arguments'].__delitem__(slice(-2, None)),
            lambda v: v['arguments'].__delitem__(slice(-4, -2)),
            lambda v: v['arguments'].extend(['--prefill-owner-trace-file', '@rank/owner-trace.json']),
            lambda v: v['arguments'].__setitem__(-1, '@rank/phase-trace.json'),
            lambda v: v.update(rank=False), lambda v: v.update(timeout_seconds=300.0),
            lambda v: v['environment'].update(MLX_METAL_GPU_ARCH='changed'),
            lambda v: v['input_files'].update(prompt=[1]),
            lambda v: v['arguments'].extend(['--unknown', 'value'])]
        for mutate in mutations:
            value = copy.deepcopy(original)
            mutate(value)
            with self.assertRaises(ValueError):
                admit_run(self.run, self.replace_native('rank.json', encoded(value), copy.deepcopy(self.receipt)))

    def test_frozen_solo_path_constructor_admitted_and_old_rank_layout_rejected(self):
        layout = frozen_layout(self.receipt['run_id'])
        self.assertEqual(self.receipt['remote_paths'], layout)
        self.assertEqual(layout['bundle'], layout['native'] + '/bundle')
        self.assertNotEqual(layout['bundle'], layout['run'] + '/bundle')
        self.assertEqual(admit_run(self.run, self.pin), self.context)
        wrong = copy.deepcopy(self.receipt)
        wrong['remote_paths']['bundle'] = layout['run'] + '/bundle'
        config = frozen_configuration(wrong['remote_paths'], wrong['bundle_manifest_sha256'],
                                      wrong['inputs']['prompt_file_sha256'])
        wrong_pin = self.replace_native('rank.json', encoded(config), wrong)
        with self.assertRaisesRegex(ValueError, 'owned solo native directory'):
            admit_run(self.run, wrong_pin)
        result = retrieve(self.run, wrong_pin, self.folder / 'old-layout',
                          reader=lambda *args: self.fail('No SSH for incorrect layout'))
        self.assertFalse(result['passed'])

    def test_archive_pin_changes_or_relabelled_runtime_source_rejected(self):
        for name in ('native/stdout.jsonl', 'source-manifest.json', 'bundle/bundle.json'):
            path = self.run / name
            old = path.read_bytes()
            path.write_bytes(old + b'\n')
            with self.assertRaises(ValueError):
                admit_run(self.run, self.pin)
            path.write_bytes(old)
        value = copy.deepcopy(self.receipt)
        path = self.run / 'launcher/launch_remote_long_solo.py'
        changed = path.read_bytes() + b'\n'
        path.write_bytes(changed)
        value['launcher_files'][0].update(sha256=sha(changed), size_bytes=len(changed))
        with self.assertRaisesRegex(ValueError, 'Frozen owner'):
            admit_run(self.run, self.save(value))

    def test_wrong_pin_unsafe_alias_and_wrong_owned_path_prevent_reads(self):
        result = retrieve(self.run, 'f' * 64, self.folder / 'wrong-pin', reader=lambda *args: self.fail('Read'))
        self.assertFalse(result['passed'])
        for mutate in (lambda v: v.update(execution_host='-oBad'),
                       lambda v: v['remote_paths'].update(native='/tmp/unowned/native'),
                       lambda v: v['remote_paths'].update(bundle='/tmp/unowned/bundle')):
            value = copy.deepcopy(self.receipt)
            mutate(value)
            with self.assertRaises(ValueError):
                admit_run(self.run, self.save(value))

    def test_native_extra_record_or_stderr_is_not_accepted(self):
        stdout = (self.run / 'native/stdout.jsonl').read_bytes()
        for name, raw in [('stdout.jsonl', stdout + b'{}\n'), ('stderr.log', b'warning\n')]:
            with self.assertRaises(ValueError):
                admit_run(self.run, self.replace_native(name, raw, copy.deepcopy(self.receipt)))
            if name == 'stdout.jsonl':
                (self.run / 'native/stdout.jsonl').write_bytes(stdout)

    def test_owner_identity_clock_kind_flags_count_and_type_mismatches_rejected(self):
        context = self.context['sidecars'][1]
        metadata, raw = make_response(context)
        mutations = [lambda t: t.update(kind='qwen_prefill_local_phase_trace'),
            lambda t: t.update(schemaVersion=True), lambda t: t.update(clockSource='injected_test_clock'),
            lambda t: t['identity'].update(requestFingerprint='a' * 64),
            lambda t: t['identity'].update(role='rank0'), lambda t: t['identity'].update(profile='wrong'),
            lambda t: t['identity'].update(frameSequence=7.0), lambda t: t['identity'].update(tokenOffset=0),
            lambda t: t.update(gpuKernelTimeAsserted=True),
            lambda t: t.update(evaluationIntervalIncludesExistingErrorCheck=1),
            lambda t: t.update(maximumEvents=8.0), lambda t: t.update(events=[{}] * 7),
            lambda t: t.update(events=[{}] * 9), lambda t: t.update(unknown=True)]
        for mutate in mutations:
            trace = parse(raw)
            mutate(trace)
            changed = encoded(trace)
            with self.assertRaises(ValueError):
                decode_response(response_bytes(dict(metadata, sha256=sha(changed), size_bytes=len(changed)), changed), context)

    def test_event_values_remain_opaque_for_separate_semantic_audit(self):
        context = self.context['sidecars'][1]
        metadata, raw = make_response(context)
        trace = parse(raw)
        trace['events'] = [{'opaque': 'synthetic semantic non-fixture'}] * 8
        changed = encoded(trace)
        _, _, correlation = decode_response(response_bytes(
            dict(metadata, sha256=sha(changed), size_bytes=len(changed)), changed), context)
        self.assertFalse(correlation['event_sequence_semantics_audited'])

    def test_crossed_sidecar_path_content_and_descriptor_observations_rejected(self):
        phase, owner = self.context['sidecars']
        metadata, raw = make_response(phase)
        with self.assertRaises(ValueError):
            decode_response(response_bytes(metadata, raw), owner)
        metadata, raw = make_response(owner)
        for key, invalid in [('path', phase['remote_path']), ('mode', 0o644), ('mode', 384.0),
                             ('sha256', 'f' * 64), ('link_count', True), ('stable_descriptor_read', False)]:
            with self.assertRaises(ValueError):
                decode_response(response_bytes(dict(metadata, **{key: invalid}), raw), owner)
        for malformed in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":1e999}'):
            with self.assertRaises(ValueError):
                parse(malformed)
        with self.assertRaises(ValueError):
            decode_response(b'x' * (MAX_SIDECAR + 4098), owner)

    def test_first_failure_stops_second_read_and_preserves_primary_cleanup(self):
        def failed(*args):
            self.calls.append('phase')
            raise SSHReadFailure({'operation': 'read', 'error': 'primary'},
                [{'operation': 'cleanup', 'error': 'secondary'}], {'local_reader_ssh_client_reaped': False}, b'partial', b'err')
        result = retrieve(self.run, self.pin, self.folder / 'out', reader=failed)
        self.assertFalse(result['passed'])
        self.assertEqual(self.calls, ['phase'])
        self.assertEqual(result['primary_failure']['error'], 'primary')
        self.assertEqual(result['cleanup_errors'][0]['error'], 'secondary')
        self.assertEqual((self.folder / 'out/phase/ssh.stdout.bin').read_bytes(), b'partial')
        self.assertFalse((self.folder / 'out/owner').exists())

    def test_owner_failure_keeps_successful_phase_without_pair_pass(self):
        def reader(*args):
            if args[1].endswith('/owner-trace.json'):
                self.calls.append('owner')
                raise SSHReadFailure({'operation': 'read', 'error': 'missing owner'}, [],
                    {'local_reader_ssh_client_reaped': True}, b'', b'missing')
            return self.fake_reader(*args)
        result = retrieve(self.run, self.pin, self.folder / 'out', reader=reader)
        self.assertFalse(result['passed'])
        self.assertEqual(self.calls, ['phase', 'owner'])
        self.assertTrue(result['sidecars'][0]['passed'])
        self.assertFalse(result['sidecars'][1]['passed'])
        self.assertTrue((self.folder / 'out/phase/phase-trace.json').exists())
        self.assertEqual(result['primary_failure']['sidecar'], 'owner')

    def test_local_mutation_after_first_read_prevents_second(self):
        def reader(*args):
            result = self.fake_reader(*args)
            (self.run / 'native/stdout.jsonl').write_bytes(b'changed')
            return result
        result = retrieve(self.run, self.pin, self.folder / 'out', reader=reader)
        self.assertFalse(result['passed'])
        self.assertEqual(self.calls, ['phase'])
        self.assertTrue((self.folder / 'out/phase/phase-trace.json').exists())

    def test_existing_output_or_symlink_is_never_overwritten(self):
        output = self.folder / 'out'
        output.mkdir()
        link = self.folder / 'link'
        link.symlink_to(output)
        for target in (output, link):
            with self.assertRaises(FileExistsError):
                retrieve(self.run, self.pin, target, reader=self.fake_reader)

    def test_owner_leaf_reader_preserves_raw_mode_and_rejects_phase_leaf_and_symlinks(self):
        path = self.folder / 'owner-trace.json'
        raw = b'{"explicitly":"fabricated"}\n'
        path.write_bytes(raw)
        path.chmod(0o600)
        metadata, returned = remote_owner.read_sidecar(str(path))
        self.assertEqual(returned, raw)
        self.assertEqual(metadata['mode'], 0o600)
        self.assertFalse(metadata['remote_file_modified'])
        with self.assertRaises(ValueError):
            remote_phase.read_sidecar(str(path))
        with self.assertRaises(ValueError):
            remote_owner.read_sidecar(str(self.folder / 'phase-trace.json'))
        actual = self.folder / 'actual'
        path.rename(actual)
        path.symlink_to(actual)
        with self.assertRaises(OSError):
            remote_owner.read_sidecar(str(path))

    def test_shared_sources_and_exact_owner_leaf_only_delta(self):
        here = Path(__file__).parent
        original = here.parent / 'phase-sidecar-retrieval-draft'
        for name in ('sidecar_files.py', 'sidecar_ssh.py', 'phase_sidecar_remote_reader.py'):
            self.assertEqual((here / name).read_bytes(), (original / name).read_bytes())
        phase = (here / 'phase_sidecar_remote_reader.py').read_text()
        self.assertEqual((here / 'owner_sidecar_remote_reader.py').read_text(), phase.replace(
            "components[-1] == 'phase-trace.json', 'Expected canonical phase sidecar path'",
            "components[-1] == 'owner-trace.json', 'Expected canonical owner sidecar path'"))


if __name__ == '__main__':
    unittest.main()
