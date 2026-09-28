"""Prevent implicit real loopback, oversized work and unverifiable captures."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from runtime import configuration, local_correctness, reports
from runtime.persistent import PersistentCohort
from test_runtime_contract import run_spec
from test_runtime_reports import bind_storage, make_report


class LocalCorrectnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='local-correctness-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / 'model'
        self.model.mkdir()
        self.config = dict(model_type='qwen3_5', text_config=dict(
            model_type='qwen3_5_text', vocab_size=512, max_position_embeddings=8192),
            mtp_config=dict(model_type='qwen3_5_mtp'))
        self.publish_config()

    def publish_config(self, config=None, directory=None):
        directory = directory or self.model
        directory.mkdir(exist_ok=True)
        data = json.dumps(config or self.config).encode()
        (directory / 'config.json').write_bytes(data)
        (directory / 'fixture-weight.bin').write_bytes(b'CPU fixture only')
        entries = [dict(path=name, size_bytes=(directory/name).stat().st_size,
                        sha256=hashlib.sha256((directory/name).read_bytes()).hexdigest())
                   for name in ('config.json', 'fixture-weight.bin')]
        aggregate = hashlib.sha256(b''.join(bytes.fromhex(entry['sha256']) for entry in entries)).hexdigest()
        manifest = dict(schema_version=1, aggregate_sha256=aggregate, file_count=2,
                        total_size_bytes=sum(entry['size_bytes'] for entry in entries), files=entries)
        (directory / 'manifest.json').write_text(json.dumps(manifest))
        if directory == self.model:
            self.aggregate = aggregate
        return aggregate

    def raw(self):
        return dict(schema_version=1, backend='loopback-test', local_correctness=True,
                    partition='ffn', artifact_aggregate_sha256=self.aggregate,
                    ranks=[dict(location='local', model_directory=str(self.model)) for _ in range(2)],
                    timeout_seconds=180, capture_logits=True,
                    workload=dict(synthetic=False, prompt_ids=[3, 9, 14, 18], chunk_size=32,
                                  decode_tokens=4, teacher_tokens=[11, 12, 13], repeats=1, warmups=0))

    def spec(self):
        return configuration.validate(self.raw())

    def report(self, spec, rank=0):
        record = make_report(spec, rank)
        record['configurationSHA256'] = hashlib.sha256((self.model/'config.json').read_bytes()).hexdigest()
        record['vocabularySize'] = self.config['text_config']['vocab_size']
        return record

    def manifest_change(self, **changes):
        path = self.model/'manifest.json'
        manifest = json.loads(path.read_text()); manifest.update(changes)
        path.write_text(json.dumps(manifest))

    def test_real_loopback_still_rejects_absent_or_false_opt_in(self):
        for supplied in (False, None):
            raw = self.raw()
            if supplied is None:
                del raw['local_correctness']
            else:
                raw['local_correctness'] = supplied
            with self.assertRaisesRegex(ValueError, 'Loopback'):
                configuration.validate(raw)
        ordinary = configuration.validate(run_spec(synthetic=False))
        self.assertNotIn('local_correctness', ordinary)
        args = configuration.rank_configuration(ordinary, 0, '/bundle', 'a'*64, [])['arguments']
        self.assertNotIn('--local-correctness', args)
        self.assertNotIn('--artifact-aggregate-sha256', args)
        synthetic = configuration.validate(run_spec('loopback-test'))
        self.assertNotIn('local_correctness', synthetic)

    def test_only_literal_boolean_opt_in_is_allowed(self):
        for value in (1, 0, 1.0, 'true', 'false', None, [], {}):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'Boolean'):
                raw = self.raw(); raw['local_correctness'] = value
                configuration.validate(raw)

    def test_valid_paths_partitions_and_policies_forward_same_bounded_contract(self):
        for path in ('ordinary', 'cbv2-contiguous'):
            for partition in ('ffn', 'full'):
                for attention, ffn in (('native', 'native'), ('native', 'float32'), ('float32', 'float32')):
                    raw = self.raw(); raw['partition'] = partition
                    raw['workload'].update(execution_path=path, attention_output_precision=attention,
                                           ffn_output_precision=ffn)
                    spec = configuration.validate(raw)
                    peers = [configuration.rank_configuration(spec, rank, '/bundle', 'b'*64,
                              [['127.0.0.1:32001'], ['127.0.0.1:32002']]) for rank in (0, 1)]
                    for rank, peer in enumerate(peers):
                        args = peer['arguments']
                        self.assertEqual(args.count('--local-correctness'), 1)
                        self.assertEqual(args.count('--artifact-aggregate-sha256'), 1)
                        self.assertEqual(args[args.index('--artifact-aggregate-sha256')+1], self.aggregate)
                        self.assertEqual(peer['input_files']['prompt.json'], spec['workload']['prompt_ids'])
                        self.assertEqual(peer['input_files']['teacher.json'], [11, 12, 13])
                        self.assertIn('--logits-file', args)
                        self.assertEqual(peer['environment']['MLX_RANK'], str(rank))
                        reports.validate_report(self.report(spec, rank), spec, rank)
                    self.assertEqual(peers[0]['arguments'], peers[1]['arguments'])

    def test_other_backends_remote_locations_and_synthetic_models_cannot_opt_in(self):
        for backend in ('solo', 'replicas', 'jaccl'):
            raw = self.raw(); raw['backend'] = backend
            if backend == 'solo': raw['ranks'] = raw['ranks'][:1]
            if backend == 'jaccl':
                raw.update(coordinator='192.0.2.1:29001', devices=['rdma_en1', 'rdma_en1'])
                for rank, entry in enumerate(raw['ranks']): entry.update(location='ssh', host=f'node-{rank}')
            with self.subTest(backend=backend), self.assertRaises(ValueError): configuration.validate(raw)
        for changes in ({'location':'ssh', 'host':'node-1'}, {'host':'unexpected-host'}):
            raw = self.raw(); raw['ranks'][1].update(changes)
            with self.assertRaises(ValueError): configuration.validate(raw)
        raw = self.raw(); raw['workload']['synthetic'] = True
        with self.assertRaisesRegex(ValueError, 'real dense Qwen'): configuration.validate(raw)

    def test_bounds_require_actual_prompt_teacher_capture_and_finite_deadline(self):
        cases = [dict(prompt_ids=[]), dict(prompt_ids=[1]*129), dict(prompt_ids=[True]),
                 dict(prompt_tokens=5), dict(chunk_size=33), dict(chunk_size=0),
                 dict(decode_tokens=5, teacher_tokens=[1]*4), dict(decode_tokens=0),
                 dict(teacher_tokens=None), dict(teacher_tokens=[]), dict(teacher_tokens=[1,2,True]),
                 dict(repeats=2), dict(warmups=1), dict(ffn_branch_precision='float32')]
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                raw=self.raw(); raw['workload'].update(changes); configuration.validate(raw)
        raw=self.raw(); del raw['workload']['prompt_ids']
        with self.assertRaises(ValueError): configuration.validate(raw)
        for changes in (dict(capture_logits=False), dict(timeout_seconds=181), dict(timeout_seconds=0),
                        dict(timeout_seconds=True)):
            raw=self.raw(); raw.update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError): configuration.validate(raw)
        for output, teacher in ((1, None), (1, []), (4, [1,2,3])):
            raw=self.raw(); raw['workload'].update(prompt_ids=[1]*128, decode_tokens=output)
            if teacher is None: del raw['workload']['teacher_tokens']
            else: raw['workload']['teacher_tokens']=teacher
            configuration.validate(raw)

    def test_manifest_expected_identity_config_binding_and_payload_cap_are_checked(self):
        for expected in (None, '', 'A'*64, '0'*64):
            raw=self.raw(); raw['artifact_aggregate_sha256']=expected
            with self.subTest(expected=expected), self.assertRaises(ValueError): configuration.validate(raw)
        for changes in (dict(total_size_bytes=8*1024**3+1), dict(total_size_bytes=True),
                        dict(aggregate_sha256='0'*64), dict(schema_version=True)):
            self.publish_config(); raw=self.raw(); self.manifest_change(**changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError): configuration.validate(raw)
        self.publish_config(); raw=self.raw()
        (self.model/'config.json').write_text(json.dumps(dict(self.config, changed=True)))
        with self.assertRaisesRegex(ValueError, 'configuration bytes'): configuration.validate(raw)

    def test_metadata_rejects_unsupported_family_experts_bad_ids_context_and_capture_product(self):
        for family, experts in (('gemma4', 0), ('qwen3_5_moe', 16), ('qwen3_5', 16), ('qwen3_5', True)):
            config=copy.deepcopy(self.config); config['model_type']=family
            config['text_config']['num_experts']=experts
            self.publish_config(config)
            with self.subTest(family=family, experts=experts), self.assertRaisesRegex(ValueError, 'dense Qwen'):
                configuration.validate(self.raw())
        for changes in (dict(vocab_size=True), dict(vocab_size=262145), dict(max_position_embeddings=7),
                        dict(max_position_embeddings=None)):
            config=copy.deepcopy(self.config); config['text_config'].update(changes)
            self.publish_config(config)
            with self.subTest(changes=changes), self.assertRaises(ValueError): configuration.validate(self.raw())
        self.publish_config()
        for field, values in [('prompt_ids',[512]), ('teacher_tokens',[1,2,512])]:
            raw=self.raw(); raw['workload'][field]=values
            with self.assertRaisesRegex(ValueError, 'vocabulary'): configuration.validate(raw)
        config=copy.deepcopy(self.config); config['text_config']['vocab_size']=262144
        self.publish_config(config); configuration.validate(self.raw())

    def test_different_rank_configuration_and_duplicate_json_are_rejected(self):
        raw=self.raw(); other=self.root/'other'; self.publish_config(directory=other)
        config=copy.deepcopy(self.config); config['text_config']['max_position_embeddings']=4096
        self.publish_config(config, other)
        # A forged same aggregate does not bypass config identity disagreement.
        m=json.loads((other/'manifest.json').read_text()); m['aggregate_sha256']=self.aggregate
        (other/'manifest.json').write_text(json.dumps(m))
        raw['ranks'][1]['model_directory']=str(other)
        with self.assertRaisesRegex(ValueError, 'configuration identities differ'): configuration.validate(raw)
        (self.model/'config.json').write_text('{"model_type":"qwen3_5","model_type":"gemma4"}')
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'): configuration.validate(self.raw())

    def test_actual_metadata_and_capture_reads_have_byte_bounds(self):
        for name, limit in (('config.json',local_correctness.MAX_CONFIG_JSON_BYTES),
                            ('manifest.json',local_correctness.MAX_MANIFEST_JSON_BYTES)):
            self.publish_config()
            path=self.model/name
            with path.open('ab') as stream: stream.write(b' '*(limit+1-path.stat().st_size))
            with self.subTest(name=name),self.assertRaisesRegex(ValueError,'byte JSON limit'):
                configuration.validate(self.raw())
        self.publish_config(); spec=self.spec(); record=self.report(spec)
        path=self.root/'oversized-logits.json'
        with path.open('wb') as stream: stream.truncate(local_correctness.MAX_CAPTURE_JSON_BYTES+1)
        with self.assertRaisesRegex(ValueError,'exceeds 32 MiB'):
            local_correctness.validate_capture(path,record,spec)
        # A file can grow between stat and open. The actual read must still stop
        # at limit+1 and reject before JSON parsing, even with a stale small stat.
        with patch.object(Path,'stat',return_value=SimpleNamespace(st_size=1)):
            with self.assertRaisesRegex(ValueError,'byte JSON limit'):
                local_correctness.validate_capture(path,record,spec)

    def test_persistent_rejects_before_metadata_reads_staging_or_process_creation(self):
        raw=self.raw(); raw['ranks'][0]['model_directory']=str(self.root/'absent')
        output=self.root/'never-staged'
        with self.assertRaisesRegex(ValueError, 'one-shot'):
            PersistentCohort(raw, self.root/'absent-bundle', output)
        self.assertFalse(output.exists())

    def test_cli_invalid_metadata_or_bounds_never_creates_output_or_starts_executable(self):
        bundle=self.root/'bundle'; bundle.mkdir()
        marker=self.root/'executed'
        executable=bundle/'cluster-inference'
        executable.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nPath({str(marker)!r}).touch()\n')
        executable.chmod(0o700)
        for field, value in (('capture_logits',False), ('timeout_seconds',181), ('artifact_aggregate_sha256','0'*64)):
            raw=self.raw(); raw[field]=value
            specfile=self.root/'spec.json'; specfile.write_text(json.dumps(raw))
            output=self.root/'output'
            result=subprocess.run([sys.executable, str(Path(__file__).parent/'run_inference.py'),
                '--spec',str(specfile),'--bundle',str(bundle),'--output',str(output)],
                capture_output=True,text=True,timeout=5)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(output.exists()); self.assertFalse(marker.exists())

    def test_reports_cannot_discard_opt_in_identity_or_nonperformance_flags(self):
        spec=self.spec(); good=self.report(spec)
        for changes in (dict(modelFamily='gemma4'),dict(feedForwardKind='moe'),dict(correctnessOnly=False),
                        dict(throughputMeasurementValid=True),dict(syntheticWeights=True),dict(mtpEnabled=True),
                        dict(transport='jaccl'),dict(worldSize=1),dict(rank=1),dict(configurationSHA256='0'*64),
                        dict(vocabularySize=513),dict(directShardLoad=None),dict(mode='baseline')):
            record=copy.deepcopy(good); record.update(changes)
            with self.subTest(changes=changes),self.assertRaises(ValueError): reports.validate_report(record,spec,0)
        record=copy.deepcopy(good); record['directShardLoad']['verifiedAggregateSHA256']='0'*64
        with self.assertRaises(ValueError): reports.validate_report(record,spec,0)
        for value in (False,None):
            changed=copy.deepcopy(spec)
            if value is None: del changed['local_correctness']
            else: changed['local_correctness']=value
            with self.assertRaisesRegex(ValueError,'explicit opt-in'): reports.validate_report(good,changed,0)

    def test_report_caps_apply_to_shared_storage_and_largest_host_tensor(self):
        spec=self.spec()
        for source, sharded, largest, accepted in (
            (6*1024**3,4*1024**3,512*1024**2,True),
            (6*1024**3+2,4*1024**3,512*1024**2,False),
            (6*1024**3,3*1024**3,512*1024**2,False),
            (2*1024**3,1024**3,512*1024**2+1,False)):
            record=self.report(spec)
            record['directShardLoad'].update(sourceModelTensorBytes=source,sourceFFNTensorBytes=sharded,
                sourceShardedFFNTensorBytes=sharded,sourceShardedTensorBytes=sharded,largestHostTensorBytes=largest)
            bind_storage(record)
            with self.subTest(source=source,sharded=sharded,largest=largest):
                if accepted: reports.validate_report(record,spec,0)
                else:
                    with self.assertRaisesRegex(ValueError,'local_correctness'): reports.validate_report(record,spec,0)

    def saved_reports(self):
        spec=self.spec(); descriptors=[]
        for rank in (0,1):
            directory=self.root/f'rank-{rank}'; directory.mkdir(exist_ok=True)
            (directory/'stdout.jsonl').write_text(json.dumps(self.report(spec,rank))+'\n')
            rows=[[1.0 if token==step else 0.0 for token in range(512)] for step in range(4)]
            (directory/'logits.json').write_text(json.dumps(rows))
            descriptors.append(dict(rank=rank,local=str(directory)))
        return spec,descriptors

    def test_complete_captures_are_required_and_bound_to_each_rank_local_argmax(self):
        spec,ranks=self.saved_reports()
        self.assertEqual(len(reports.reports(ranks,spec)),2)
        path=self.root/'rank-1/logits.json'; original=path.read_text()
        path.unlink()
        with self.assertRaisesRegex(ValueError,'captured logits'): reports.reports(ranks,spec)
        for rows in ([],[[0]*512]*3,[[0]*511]*4,[[True]*512]*4,[[float('nan')]*512]*4,[[0]*512]*4):
            path.write_text(json.dumps(rows))
            with self.subTest(case=str(rows)[:30]),self.assertRaises(ValueError): reports.reports(ranks,spec)
        path.write_text(original)
        reportpath=self.root/'rank-1/stdout.jsonl'; peer=json.loads(reportpath.read_text())
        peer['runs'][0]['localArgmaxTokens'][0]=2; peer['runs'][0]['localArgmaxDisagreementCount']=1
        reportpath.write_text(json.dumps(peer)+'\n')
        with self.assertRaisesRegex(ValueError,'reported local argmax'): reports.reports(ranks,spec)


if __name__ == '__main__':
    unittest.main()
