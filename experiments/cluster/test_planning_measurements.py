import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from runtime.stage_checks.common import canonical, digest
from planning.measurements.__main__ import main
from planning.measurements.packet import extract
from planning.measurements.projection import assumed_profile
from planning.measurements.qwen_rank_phase import validate_phase_pair
from planning.rank import analyze
from planning_measurement_test_support import fabricated_phase
from stage_long_test_support import context, rows
from stage_long_cut_test_support import selected_context, selected_rows


def fabricated_pair(policy='serial_v1', cut=None):
    ctx = selected_context() if cut == 12 else context()
    ctx['stage_prefill_policy'] = policy
    values, traces = [], []
    for rank in range(2):
        pair = selected_rows(rank, ctx) if cut == 12 else rows(rank, ctx)
        pair[1], trace = fabricated_phase(pair[1], clock_origin=1000 + rank * 10**12)
        values.append(pair)
        traces.append(trace)
    return ctx, values, traces


def write_packet(folder, *, policy='serial_v1', cut=None, mutate=None):
    ctx, values, traces = fabricated_pair(policy, cut)
    if mutate:
        mutate(values, traces)
    raw_files = dict(prompt=canonical(ctx['prompt']) + b'\n')
    for rank in range(2):
        raw_files[f'rank{rank}_stdout'] = b''.join(canonical(value) + b'\n' for value in values[rank])
        raw_files[f'rank{rank}_trace'] = canonical(traces[rank])
    refs = {}
    for name, raw in raw_files.items():
        (folder / (name + '.json')).write_bytes(raw)
        refs[name] = dict(path=name + '.json', sha256=digest(raw))
    provenance = {name: str(index) * 64 for index, name in enumerate(
        ('native_sha256', 'runtime_source_sha256', 'numerical_audit_sha256', 'runtime_audit_sha256'), 1)}
    provenance['devices'] = [dict(id='fabricated-observed-device', hardware_sha256='5' * 64) for _ in range(2)]
    packet = dict(schema='cluster_qwen_prefill_measurement_packet_v1', stage_cut=cut,
                  files=refs, provenance=provenance)
    path = folder / 'packet.json'
    path.write_bytes(canonical(packet))
    return path


class MeasurementTests(unittest.TestCase):
    def test_both_policies_preserve_services_and_do_not_align_clocks(self):
        for policy in ('serial_v1', 'prompt_lookahead_one_v1'):
            with self.subTest(policy=policy), tempfile.TemporaryDirectory() as directory:
                result = extract(write_packet(Path(directory), policy=policy))
                self.assertEqual(result['observed']['resource_layout'], 'shared_device')
                ranks = result['phase']['ranks']
                self.assertEqual([row['totalServiceNanoseconds'] for row in ranks], [160, 160])
                self.assertTrue(ranks[1]['services'][-1]['includesFinalSelection'])
                self.assertTrue(all(not row['includesFinalSelection'] for row in ranks[0]['services']))
                self.assertEqual(ranks[0]['serialPreHeaderServices'] is None, policy != 'serial_v1')
                self.assertIsNone(ranks[1]['serialPreHeaderServices'])
                self.assertGreater(ranks[1]['firstLocalUptimeNanoseconds'], ranks[0]['lastLocalUptimeNanoseconds'])
                self.assertFalse(result['phase']['crossProcessClockAlignmentAsserted'])
                self.assertNotIn('"promptTokenIDs":', json.dumps(result))
                self.assertNotIn(directory, json.dumps(result))

    def test_cut12_uses_existing_native_identity_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            result = extract(write_packet(Path(directory), cut=12))
            self.assertEqual(result['observed']['stage_cut'], 12)
            self.assertEqual(len(set(result['source']['source_parameter_layout_sha256'])), 1)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                extract(write_packet(Path(directory), cut=12, policy='prompt_lookahead_one_v1'))

    def test_explicit_projection_preserves_unmeasured_work(self):
        with tempfile.TemporaryDirectory() as directory:
            services = extract(write_packet(Path(directory)))
            document = assumed_profile(services, ['hypothetical-a', 'hypothetical-b'], 'prompt_lookahead_one_v1')
            candidate = document['candidates'][0]
            self.assertEqual(candidate['evidence_kind'], 'assumed')
            self.assertEqual(candidate['plan_sha256'], services['source']['plan_sha256'])
            result = analyze(document)
            self.assertEqual(result['comparisons'], [])
            self.assertEqual(len(result['candidates'][0]['missing_costs']), 34)
            self.assertEqual(len(result['candidates'][0]['memory_issues']), 4)
            self.assertEqual(result['candidates'][0]['zero_overhead_scenario_ns']['typical'], 170)
            self.assertIsNone(result['candidates'][0]['ttft_ns'])
            with self.assertRaises(ValueError):
                assumed_profile(services, ['same', 'same'])

    def test_external_provenance_is_retained_without_minting_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_packet(Path(directory))
            result = extract(path)
            self.assertEqual(result['observed']['provenance']['native_sha256'], '1' * 64)
            for flag in ('numerical_audit_replayed', 'runtime_provenance_audit_replayed',
                         'hardware_identity_verified', 'native_execution_performed',
                         'physical_performance_qualified', 'execution_admission'):
                self.assertFalse(result[flag])
            document = json.loads(path.read_bytes())
            document['provenance']['devices'][1]['id'] = 'a-different-device'
            path.write_bytes(canonical(document))
            with self.assertRaises(ValueError):
                extract(path)

    def test_action_commit_history_and_scope_tampering(self):
        mutations = [
            lambda r, t: r[0][1]['execution']['actions'][6].update(explicitPreparedBoundarySlots=2),
            lambda r, t: r[0][1]['execution']['frames'][3]['commit'].update(committedTokens=2049),
            lambda r, t: r[1][1].update(physicalTransferQualified=True),
            lambda r, t: r[0][1]['request']['promptTokenIDs'].__setitem__(0, 2),
            lambda r, t: r[0][1]['sourceLoad'].update(planSHA256='e' * 64),
            lambda r, t: r[0][1]['arithmeticEnvironment']['requiredValues'].update(MLX_ENABLE_TF32='0'),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(case=index), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    extract(write_packet(Path(directory), mutate=mutation))

    def test_phase_rejects_clock_schema_identity_and_order_changes(self):
        mutations = [
            lambda r, t: t[0]['events'][6].update(localUptimeNanoseconds=0),
            lambda r, t: t[1]['events'][8].update(localUptimeNanoseconds=True),
            lambda r, t: t[0]['events'][6].update(frameSequence=1),
            lambda r, t: t[0].update(traceSpanNanoseconds=1),
            lambda r, t: t[1]['identity'].update(requestFingerprint='e' * 64),
            lambda r, t: t[1].update(gpuOverlapAsserted=True),
            lambda r, t: t[0]['events'].pop(),
            lambda r, t: r[0][1]['execution']['timing'].update(elapsedNanoseconds=1),
            lambda r, t: r[0][1]['execution']['timing'].update(promptTokensPerFirstTokenSecond=1.0),
            lambda r, t: r[1][1]['execution'].update(timing={}),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(case=index), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    extract(write_packet(Path(directory), mutate=mutation))

    def test_coherent_clock_shift_preserves_services_but_has_no_native_proof(self):
        _, rows, traces = fabricated_pair()
        original = validate_phase_pair([r[1] for r in rows], traces)
        changed = copy.deepcopy(traces)
        for event in changed[1]['events']:
            event['localUptimeNanoseconds'] += 10**15
        for key in ('firstLocalUptimeNanoseconds', 'lastLocalUptimeNanoseconds'):
            changed[1][key] += 10**15
        shifted = validate_phase_pair([r[1] for r in rows], changed)
        self.assertEqual(original['ranks'][1]['services'], shifted['ranks'][1]['services'])
        self.assertFalse(shifted['nativeExecutionIndependentlyVerified'])

    def test_public_cli_observed_and_assumed_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_packet(Path(directory))
            for args, schema in (([], 'cluster_prefill_services_v1'),
                                 (['--assume-independent-devices', 'a', 'b', '--policy', 'prompt_lookahead_one_v1'],
                                  'cluster_prefill_costs_v1')):
                output = io.StringIO()
                with patch('sys.argv', ['measurements', str(path), *args]), contextlib.redirect_stdout(output):
                    self.assertEqual(main(), 0)
                self.assertEqual(json.loads(output.getvalue())['schema'], schema)


if __name__ == '__main__':
    unittest.main()
