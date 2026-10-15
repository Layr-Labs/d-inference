"""Native report fixtures exercise acceptance without starting a model or SSH."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from runtime import configuration, reports


def bind_storage(record, selected=None):
    """Build fixture evidence independently, after deliberately changing a receipt."""
    source = record.get('directShardLoad', {})
    total = source.get('sourceModelTensorBytes', 1000)
    sharded = source.get('sourceShardedTensorBytes', 800 if record['partition'] == 'full' else 600)
    selected = selected or [sharded // 2, sharded - sharded // 2]
    layouts = ['c' * 64, ('e' if selected[0] != selected[1] else 'c') * 64]
    storage = dict(schemaVersion=1, sourceTensorManifestSHA256='f' * 64,
                   sourceModelTensorBytes=total, sourceFFNTensorBytes=source.get('sourceFFNTensorBytes', 600),
                   sourceShardedFFNTensorBytes=source.get('sourceShardedFFNTensorBytes', 600),
                   sourceShardedTensorBytes=sharded,
                   ranks=[dict(rank=i, parameterLayoutSHA256=layouts[i],
                               loadedTensorBytes=total-sharded+selected[i], selectedShardedTensorBytes=selected[i])
                          for i in range(2)])
    record['partitionStorage'] = storage
    record['parameterLayoutSHA256'] = layouts[record['rank']]
    if source:
        source['partitionStorage'] = copy.deepcopy(storage)
        source['loadedTensorBytes'] = storage['ranks'][record['rank']]['loadedTensorBytes']


def token_hash(tokens):
    return hashlib.sha256(json.dumps(tokens, separators=(',', ':')).encode()).hexdigest()


def make_spec(backend='solo', synthetic=True, supplied_prompt=True, decode=3, partition='ffn',
              synthetic_dtype='float32', synthetic_profile='tiny', attention_output_precision='native',
              ffn_branch_precision='native'):
    ranks = [dict(location='local') for _ in range(1 if backend == 'solo' else 2)]
    spec = dict(schema_version=1, backend=backend, ranks=ranks, capture_logits=False, partition=partition,
                workload=dict(synthetic=synthetic, prompt_tokens=4, chunk_size=3,
                              decode_tokens=decode, repeats=2, warmups=1, seed=7,
                              attention_output_precision=attention_output_precision,
                              ffn_branch_precision=ffn_branch_precision))
    if supplied_prompt:
        spec['workload']['prompt_ids'] = [3, 9, 14, 18]
    if synthetic:
        spec['workload']['synthetic_dtype'] = synthetic_dtype
        spec['workload']['synthetic_profile'] = synthetic_profile
    if backend in ('jaccl', 'loopback-test'):
        spec['workload']['teacher_tokens'] = [11] * (decode - 1)
    if backend == 'jaccl':
        spec.update(coordinator='192.0.2.1:29500', devices=['rdma_en1', 'rdma_en2'])
        for index, rank in enumerate(ranks):
            rank.update(location='ssh', host=f'fixture-node-{index}')
    if not synthetic:
        spec['artifact_aggregate_sha256'] = 'd' * 64
        for rank in ranks:
            rank['model_directory'] = '/isolated/model'
    return configuration.validate(spec)


def make_report(spec, rank=0):
    work, backend = spec['workload'], spec['backend']
    synthetic = work['synthetic']
    cooperative = backend in ('jaccl', 'loopback-test')
    record = dict(
        schemaVersion=7, mode='ffn-tp' if cooperative else 'baseline',
        partition=spec['partition'] if cooperative else 'none',
        model=f'synthetic-qwen35-w4g64-seed-{work["seed"]}' if synthetic else 'model',
        modelFamily='qwen35',
        configurationSHA256='a' * 64, parameterLayoutSHA256='c' * 64,
        promptSHA256=token_hash(work['prompt_ids']) if 'prompt_ids' in work else '1' * 64,
        rank=rank if cooperative else 0, worldSize=2 if cooperative else 1,
        promptSource='token-file' if 'prompt_ids' in work else 'synthetic-token-ids',
        teacherForced=work.get('teacher_tokens') is not None, chunkSize=work['chunk_size'],
        tokenSelectionPolicy='rank0-greedy' if cooperative else 'local-greedy', vocabularySize=512,
        attentionOutputPrecision=work['attention_output_precision'],
        ffnBranchPrecision=work['ffn_branch_precision'],
        loadSeconds=0.2, syntheticWeights=synthetic, mtpEnabled=False,
        feedForwardKind='moe' if synthetic and work['synthetic_profile'] == 'qwen-moe' else 'dense',
        shardedFFNs=4 if cooperative else 0, seed=work['seed'], timestamp='2026-09-13T23:48:55Z',
        embeddingActivationDType=work['synthetic_dtype'] if synthetic else 'bfloat16',
        ffnScaleDTypes=[work['synthetic_dtype'] if synthetic else 'bfloat16'],
        bf16ConversionEnabled=not synthetic,
        throughputMeasurementValid=backend != 'loopback-test' and not (cooperative and spec['capture_logits']),
        transport=backend if cooperative else 'none', correctnessOnly=backend == 'loopback-test',
        decodeScheduling='synchronous-per-token',
        prefillDefinition='all prompt tokens through first generated token', runs=[])
    if synthetic:
        record['syntheticDType'] = work['synthetic_dtype']
        record['syntheticProfile'] = work['synthetic_profile']
        if work['synthetic_profile'] in ('gemma-moe', 'gemma-moe-w8'):
            quantization = 'mixed-w4w8g64' if work['synthetic_profile'] == 'gemma-moe' else 'w8g64'
            record.update(modelFamily='gemma4', model=f'synthetic-gemma4-{quantization}-seed-{work["seed"]}',
                          feedForwardKind='moe')
    if record['teacherForced']:
        record['teacherSHA256'] = token_hash(work['teacher_tokens'])
    if cooperative:
        record['partitionPlanSHA256'] = hashlib.sha256(('fixture-plan-' + spec['partition']).encode()).hexdigest()
    if cooperative and not synthetic:
        sharded = 800 if spec['partition'] == 'full' else 600
        record['directShardLoad'] = dict(
            verifiedAggregateSHA256=spec['artifact_aggregate_sha256'],
            sourceModelTensorBytes=1000, sourceFFNTensorBytes=600, sourceShardedFFNTensorBytes=600,
            sourceShardedTensorBytes=sharded, loadedTensorBytes=1000 - sharded // 2,
            largestHostTensorBytes=250, sourceTensorCount=42, tensorCount=42, rank=rank)
    if cooperative:
        bind_storage(record, selected=[250, 350] if record['modelFamily'] == 'gemma4' else None)
    for iteration in range(work['repeats']):
        steps = [0.05] * (work['decode_tokens'] - 1)
        elapsed = sum(steps)
        run = dict(iteration=iteration, promptTokens=work['prompt_tokens'],
                   generatedTokens=list(range(work['decode_tokens'])), prefillSeconds=0.25,
                   localArgmaxTokens=list(range(work['decode_tokens'])), localArgmaxDisagreementCount=0,
                   decodeInputTokens=list(work['teacher_tokens']) if work.get('teacher_tokens') is not None
                       else list(range(work['decode_tokens'] - 1)),
                   prefillTokensPerSecond=work['prompt_tokens'] / 0.25,
                   decodeForwardCount=len(steps), decodeSeconds=elapsed, decodeStepSeconds=steps,
                   peakMLXBytes=4096, activeMLXBytes=1024)
        if steps:
            run['decodeTokensPerSecond'] = len(steps) / elapsed
        record['runs'].append(run)
    return record


class NativeReportTests(unittest.TestCase):
    def assert_rejected(self, record, spec=None, rank=0):
        with self.assertRaises(ValueError):
            reports.validate_report(record, spec or make_spec(), rank)

    def test_current_schema_accepts_complete_baselines_replicas_and_cooperative_runs(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            for synthetic in (True, False):
                if backend == 'loopback-test' and not synthetic:
                    continue
                for supplied_prompt in (False, True):
                    for decode in (1, 3):
                        spec = make_spec(backend, synthetic, supplied_prompt, decode)
                        for rank in range(len(spec['ranks'])):
                            with self.subTest(backend=backend, synthetic=synthetic,
                                              supplied_prompt=supplied_prompt, decode=decode, rank=rank):
                                reports.validate_report(make_report(spec, rank), spec, rank)

    def test_each_required_top_level_field_must_be_present(self):
        complete = make_report(make_spec())
        for field in complete:
            record = copy.deepcopy(complete)
            del record[field]
            with self.subTest(field=field):
                self.assert_rejected(record)

    def test_each_measured_run_must_be_complete(self):
        complete = make_report(make_spec())
        for field in complete['runs'][0]:
            record = copy.deepcopy(complete)
            del record['runs'][0][field]
            with self.subTest(field=field):
                self.assert_rejected(record)

    def test_fingerprints_cannot_be_null_malformed_or_non_strings(self):
        for field in reports.FINGERPRINTS:
            for value in (None, '', 'x' * 64, 'a' * 63, [], True):
                record = make_report(make_spec())
                record[field] = value
                with self.subTest(field=field, value=value):
                    self.assert_rejected(record)

    def test_wrong_execution_identity_and_modes_are_rejected(self):
        mismatches = dict(schemaVersion=True, mode='ffn-tp', transport='ring', worldSize=2,
                          rank=1, syntheticWeights=False, chunkSize=2, seed=8,
                          mtpEnabled=True, shardedFFNs=4, bf16ConversionEnabled=True,
                          decodeScheduling='asynchronous', prefillDefinition='last chunk only')
        for field, value in mismatches.items():
            record = make_report(make_spec())
            record[field] = value
            with self.subTest(field=field):
                self.assert_rejected(record)

    def test_prior_schema_reports_are_not_accepted_by_the_new_launcher(self):
        for backend in ('solo', 'loopback-test'):
            for schema in (1, 2, 3, 4, 5, 6):
                spec = make_spec(backend)
                record = make_report(spec)
                record['schemaVersion'] = schema
                with self.subTest(backend=backend, schema=schema):
                    self.assert_rejected(record, spec)

    def test_partition_identity_and_plan_are_required_for_cooperative_reports(self):
        for backend in ('jaccl', 'loopback-test'):
            for partition in ('ffn', 'full'):
                spec = make_spec(backend, partition=partition)
                reports.validate_report(make_report(spec), spec, 0)
                for field in ('partition', 'partitionPlanSHA256'):
                    record = make_report(spec)
                    del record[field]
                    with self.subTest(backend=backend, partition=partition, missing=field):
                        self.assert_rejected(record, spec)
                for value in (None, '', 'g' * 64, 'a' * 63, 'A' * 64, [], True):
                    record = make_report(spec)
                    record['partitionPlanSHA256'] = value
                    with self.subTest(partition=partition, hash=value):
                        self.assert_rejected(record, spec)
                for value in ('none', 'full' if partition == 'ffn' else 'ffn', None):
                    record = make_report(spec)
                    record['partition'] = value
                    with self.subTest(partition=partition, wrong=value):
                        self.assert_rejected(record, spec)

    def test_baseline_has_no_partition_plan_even_when_spec_defaults_to_ffn(self):
        for backend in ('solo', 'replicas'):
            spec = make_spec(backend)
            for value in (None, 'a' * 64):
                record = make_report(spec)
                record['partitionPlanSHA256'] = value
                with self.subTest(backend=backend, value=value):
                    self.assert_rejected(record, spec)
            record = make_report(spec)
            record['partition'] = 'ffn'
            self.assert_rejected(record, spec)

    def test_supplied_prompt_hash_and_source_are_bound_to_the_spec(self):
        for field, value in (('promptSHA256', token_hash([3, 9, 14, 19])),
                             ('promptSource', 'synthetic-token-ids')):
            record = make_report(make_spec())
            record[field] = value
            self.assert_rejected(record)
        counts_only = make_spec(supplied_prompt=False)
        record = make_report(counts_only)
        record['promptSource'] = 'token-file'
        self.assert_rejected(record, counts_only)

    def test_teacher_presence_hash_and_forcing_must_match_requested_tokens(self):
        spec = make_spec('jaccl')
        for field, value in (('teacherSHA256', None), ('teacherSHA256', 'e' * 64),
                             ('teacherForced', False)):
            record = make_report(spec)
            record[field] = value
            self.assert_rejected(record, spec)
        record = make_report(make_spec())
        record['teacherSHA256'] = token_hash([])
        self.assert_rejected(record)

    def test_loopback_and_logit_capture_cannot_claim_eligible_cooperative_timing(self):
        for backend in ('jaccl', 'loopback-test'):
            spec = make_spec(backend)
            spec['capture_logits'] = True
            valid = make_report(spec)
            reports.validate_report(valid, spec, 0)
            valid['throughputMeasurementValid'] = True
            self.assert_rejected(valid, spec)
        spec = make_spec('loopback-test')
        record = make_report(spec)
        record['correctnessOnly'] = False
        self.assert_rejected(record, spec)

    def test_router_diagnostics_cannot_be_accepted_as_benchmark_reports(self):
        for backend in ('solo', 'loopback-test'):
            spec = make_spec(backend)
            for field in ('routingTraceEnabled', 'routingReplayEnabled'):
                for value in (True, False, None, 'true', 1):
                    record = make_report(spec)
                    record[field] = value
                    with self.subTest(backend=backend, field=field, value=value):
                        self.assert_rejected(record, spec)

    def test_workload_counts_and_iteration_order_must_be_complete(self):
        for field, value in (('iteration', 1), ('promptTokens', 3), ('decodeForwardCount', 1),
                             ('generatedTokens', [0, 1]), ('generatedTokens', [0, 1, True]),
                             ('decodeStepSeconds', [0.05])):
            record = make_report(make_spec())
            record['runs'][0][field] = value
            with self.subTest(field=field):
                self.assert_rejected(record)
        record = make_report(make_spec())
        record['runs'].pop()
        self.assert_rejected(record)

    def test_timing_and_memory_must_be_finite_nonnegative_and_consistent(self):
        for field, value in (('prefillSeconds', 0), ('prefillSeconds', float('nan')),
                             ('prefillSeconds', float('inf')), ('prefillSeconds', '0.25'),
                             ('prefillTokensPerSecond', 9999), ('decodeSeconds', 0.2),
                             ('decodeTokensPerSecond', 9999), ('decodeStepSeconds', [0.0, 0.1]),
                             ('activeMLXBytes', -1), ('peakMLXBytes', 10), ('peakMLXBytes', True)):
            record = make_report(make_spec())
            record['runs'][0][field] = value
            with self.subTest(field=field, value=value):
                self.assert_rejected(record)

    def test_no_decode_forward_has_no_decode_tps(self):
        spec = make_spec(decode=1)
        record = make_report(spec)
        record['runs'][0]['decodeTokensPerSecond'] = 0
        self.assert_rejected(record, spec)

    def test_dtype_and_timestamp_fields_reject_malformed_values(self):
        for field, value in (('embeddingActivationDType', []), ('embeddingActivationDType', 'uint32'),
                             ('ffnScaleDTypes', []), ('ffnScaleDTypes', ['float32', 'float32']),
                             ('ffnScaleDTypes', [None]), ('timestamp', None),
                             ('timestamp', '2026-09-13T23:48:55'), ('loadSeconds', -1)):
            record = make_report(make_spec())
            record[field] = value
            with self.subTest(field=field, value=value):
                self.assert_rejected(record)

    def test_real_cooperative_load_receipt_requires_exact_identity_and_byte_accounting(self):
        spec = make_spec('jaccl', synthetic=False)
        complete = make_report(spec)
        for field in complete['directShardLoad']:
            record = copy.deepcopy(complete)
            del record['directShardLoad'][field]
            with self.subTest(missing=field):
                self.assert_rejected(record, spec)
        for field, value in (('verifiedAggregateSHA256', 'e' * 64), ('rank', 1),
                             ('sourceFFNTensorBytes', 601), ('loadedTensorBytes', 1000),
                             ('largestHostTensorBytes', 701), ('tensorCount', 0)):
            record = copy.deepcopy(complete)
            record['directShardLoad'][field] = value
            with self.subTest(field=field):
                self.assert_rejected(record, spec)
        del complete['directShardLoad']
        self.assert_rejected(complete, spec)

    def test_direct_load_source_copy_bytes_are_not_post_conversion_residency(self):
        spec = make_spec('jaccl', synthetic=False)
        record = make_report(spec)
        for run in record['runs']:
            run.update(activeMLXBytes=350, peakMLXBytes=500)
        # The receipt still describes 700 source bytes; a dtype conversion may
        # reduce residency without changing the source artifact's byte accounting.
        reports.validate_report(record, spec, 0)

    def test_full_load_counts_attention_and_recurrent_partitions_not_only_ffns(self):
        spec = make_spec('jaccl', synthetic=False, partition='full')
        record = make_report(spec)
        reports.validate_report(record, spec, 0)
        # FFN-only accounting would report 700 bytes, but this full partition owns 600.
        record['directShardLoad']['loadedTensorBytes'] = 700
        self.assert_rejected(record, spec)
        for value in (None, True, 0, 599, 600, 799, 1002):
            record = make_report(spec)
            record['directShardLoad']['sourceShardedTensorBytes'] = value
            with self.subTest(sharded=value):
                self.assert_rejected(record, spec)
        record = make_report(spec)
        del record['directShardLoad']['sourceShardedTensorBytes']
        self.assert_rejected(record, spec)

    def test_ffn_receipts_cannot_claim_full_partition_byte_savings(self):
        spec = make_spec('jaccl', synthetic=False)
        record = make_report(spec)
        record['directShardLoad'].update(sourceShardedTensorBytes=800, loadedTensorBytes=600)
        self.assert_rejected(record, spec)

    def test_full_receipts_cannot_masquerade_as_ffn_only_with_self_consistent_bytes(self):
        spec = make_spec('jaccl', synthetic=False, partition='full')
        record = make_report(spec)
        record['directShardLoad'].update(sourceShardedTensorBytes=600, loadedTensorBytes=700)
        self.assert_rejected(record, spec)


class CohortReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, spec, records=None):
        ranks = []
        for index in range(len(spec['ranks'])):
            directory = self.root / str(index)
            directory.mkdir(exist_ok=True)
            record = make_report(spec, index) if records is None else records[index]
            (directory / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
            ranks.append(dict(rank=index, local=str(directory)))
        return ranks

    def test_cohort_requires_every_rank_once(self):
        spec = make_spec('loopback-test')
        ranks = self.write(spec)
        for candidates in ([], ranks[:1], [ranks[0], ranks[0]]):
            with self.subTest(candidates=candidates), self.assertRaises(ValueError):
                reports.reports(candidates, spec)
        self.assertEqual(len(reports.reports(list(reversed(ranks)), spec)), 2)

    def test_cross_rank_fingerprints_and_dtype_layout_must_agree(self):
        spec = make_spec('replicas', supplied_prompt=False)
        for field, value in (('configurationSHA256', 'e' * 64), ('parameterLayoutSHA256', 'e' * 64),
                             ('promptSHA256', 'e' * 64), ('ffnScaleDTypes', ['bfloat16'])):
            records = [make_report(spec), make_report(spec)]
            records[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                reports.reports(self.write(spec, records), spec)

    def test_cooperative_tokens_must_agree_but_independent_replicas_need_not(self):
        for backend in ('loopback-test', 'replicas'):
            spec = make_spec(backend)
            records = [make_report(spec, index) for index in range(2)]
            records[1]['runs'][0]['generatedTokens'][0] = 17
            records[1]['runs'][0]['localArgmaxTokens'][0] = 17
            if spec['workload'].get('teacher_tokens') is None:
                records[1]['runs'][0]['decodeInputTokens'][0] = 17
            ranks = self.write(spec, records)
            if backend == 'loopback-test':
                with self.assertRaises(ValueError):
                    reports.reports(ranks, spec)
            else:
                self.assertEqual(len(reports.reports(ranks, spec)), 2)

    def test_full_rank_plan_digests_must_agree_even_when_each_report_is_valid(self):
        spec = make_spec('loopback-test', partition='full')
        records = [make_report(spec, index) for index in range(2)]
        records[1]['partitionPlanSHA256'] = 'e' * 64
        for rank, record in enumerate(records):
            reports.validate_report(record, spec, rank)
        with self.assertRaisesRegex(ValueError, 'partitionPlanSHA256.*disagree'):
            reports.reports(self.write(spec, records), spec)

    def test_full_rank_receipts_must_agree_on_source_and_selected_tensor_bytes(self):
        spec = make_spec('jaccl', synthetic=False, partition='full')
        for replacement in (dict(sourceShardedTensorBytes=900, loadedTensorBytes=550),
                            dict(sourceFFNTensorBytes=650),
                            dict(sourceModelTensorBytes=1100, loadedTensorBytes=700)):
            records = [make_report(spec, index) for index in range(2)]
            records[1]['directShardLoad'].update(replacement)
            bind_storage(records[1])
            reports.validate_report(records[1], spec, 1)
            with self.subTest(replacement=replacement), self.assertRaisesRegex(ValueError, 'disagree'):
                reports.reports(self.write(spec, records), spec)

    def test_missing_duplicate_truncated_and_nonfinite_json_cannot_be_verified(self):
        spec = make_spec()
        ranks = self.write(spec)
        path = Path(ranks[0]['local']) / 'stdout.jsonl'
        good = path.read_text()
        for content in ('', '{}\n', good + good, good + '{"runs":\n',
                        good.replace('"loadSeconds": 0.2', '"loadSeconds": NaN'),
                        good.replace('"schemaVersion": 7', '"schemaVersion": 0,"schemaVersion": 7')):
            path.write_text(content)
            with self.subTest(content=content[:70]), self.assertRaises(ValueError):
                reports.reports(ranks, spec)
        path.write_text('native diagnostic text\n' + good)
        self.assertEqual(len(reports.reports(ranks, spec)), 1)


if __name__ == '__main__':
    unittest.main()
