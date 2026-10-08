"""Prospective CPU-only tests; rank records are invented, never native evidence."""
import copy
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest

import audit_rank_cut12 as adapter
from rank_cut12_fixture import fixture, REFERENCE, PROMPT, TEACHER, EPOCH
from rank_mutations import MUTATIONS, reheader


class RankCut12Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.audit,cls.baseline,cls.expected,cls.rows=fixture()

    def check(self, rows, expected=None, old_sha=None, epoch=EPOCH):
        kwargs={} if old_sha is None else dict(old_sha=old_sha)
        return self.audit.validate_reports(rows,self.baseline,epoch,self.expected if expected is None else expected,**kwargs)

    def test_invented_pair_positive(self):
        result=self.check(self.rows)
        self.assertEqual(result['combinedStateEntriesChecked'],432)
        self.assertEqual(result['nativeLogitValuesPerSide'],993280)
        self.assertEqual(result['stageActiveTensorBytes'],[2032294848,3005746752])
        self.assertTrue(all(frame['stateEntriesPerStage']==[27,45] for frame in result['frames']))
        self.assertFalse(result['observedBoundaryPayloadBytesAvailable'])

    def test_invented_file_pair_positive(self):
        with tempfile.TemporaryDirectory(prefix='cpu-cut12-rank-fixture-') as tmp:
            files=[]
            for rank,rows in enumerate(self.rows):
                file=Path(tmp)/f'rank{rank}.jsonl'
                file.write_bytes(b''.join(self.audit.canonical(row)+b'\n' for row in rows));files.append(file)
            result=adapter.validate(files,REFERENCE,EPOCH,PROMPT,TEACHER)
            self.assertTrue(result['inputFilesUnchangedAfterReplay'])
            self.assertEqual(result['candidateRawLogitRowsReconstructed'],4)

    def test_signed_zero(self):
        record=dict(shape=[1,2],dtype='bfloat16',byteCount=4,
            logicalBytesSHA256=self.audit.digest(b'\x00\x80\x00\x00'),values=[-0.0,0.0])
        self.assertEqual(self.audit.base_helper().logical_bytes(record,2,'bfloat16'),b'\x00\x80\x00\x00')
        record['values'][0]=0.0
        with self.assertRaisesRegex(ValueError,'SHA differs'):
            self.audit.base_helper().logical_bytes(record,2,'bfloat16')

    def test_coherent_boundary_digest_is_documented_limit(self):
        rows=copy.deepcopy(self.rows)
        for rank in range(2):rows[rank][1]['frames'][0]['capture']['boundaryPayloadSHA256']='a'*64
        reheader(rows)
        result=self.check(rows)
        self.assertFalse(result['hiddenCutpointComparedToPriorBaseline'])
        self.assertFalse(result['observedACKBytesAvailable'])

    def test_old16_reference_raw_pin_rejected(self):
        with self.assertRaisesRegex(ValueError,'Reference baseline stdout identity'):
            self.check(self.rows,old_sha='dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551')

    def test_changed_expected_metadata_rejected(self):
        expected=copy.deepcopy(self.expected);expected['layers']=31
        with self.assertRaisesRegex(ValueError,'expected metadata changed'):
            self.check(self.rows,expected=expected)

    def test_reused_reference_epoch_rejected(self):
        epoch=self.baseline[0]['baseline']['request']['request']['requestID'].replace('-','').lower()
        with self.assertRaisesRegex(ValueError,'reuse prior baseline UUID'):
            self.check(self.rows,epoch=epoch)

    def test_old_half_ranges_rejected(self):
        rows=copy.deepcopy(self.rows)
        for rank in range(2):
            for completion in rows[rank][1]['frames']:
                completion['capture'].update(sourceLayerStart=rank*16,sourceLayerEnd=(rank+1)*16)
        with self.assertRaisesRegex(ValueError,'source range'):
            self.check(rows)

    def test_coherent_layer12_wrong_owner_rejected(self):
        rows=copy.deepcopy(self.rows)
        left,right=[r[1]['frames'][0]['capture'] for r in rows]
        moved=[x for x in right['stateEntries'] if x['globalLayerIndex']==12]
        self.assertTrue(moved)
        left['stateEntries']+=moved
        right['stateEntries']=[x for x in right['stateEntries'] if x['globalLayerIndex']!=12]
        for capture in (left,right):
            capture['stateEntries'].sort(key=lambda x:(x['globalLayerIndex'],x['component']))
            capture['logicalStateBytes']=sum(x['byteCount'] for x in capture['stateEntries'])
            capture['stageStateSHA256']=self.audit.state_hash(capture['stateEntries'],capture['committedTokens'])
        with self.assertRaisesRegex(ValueError,'Rank state metadata/digest'):
            self.check(rows)

    def test_old_plan_pin_rejected(self):
        rows=copy.deepcopy(self.rows)
        for rank in range(2):
            rows[rank][1]['sourceLoad']['planSHA256']='2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293'
        with self.assertRaisesRegex(ValueError,'sourceLoad'):
            self.check(rows)

    def test_wrong_construction_pins_rejected(self):
        rows=copy.deepcopy(self.rows)
        for rank in range(2):rows[rank][1]['sourceLoad']['constructionConfigurationSHA256']='a'*64
        with self.assertRaisesRegex(ValueError,'sourceLoad'):
            self.check(rows)

    def test_wrong_local_layer_mapping_rejected(self):
        rows=copy.deepcopy(self.rows); tensors=rows[1][1]['sourceLoad']['activeTensors']
        item=next(t for t in tensors if '.layers.12.' in t['sourceName'])
        self.assertIn('.layers.0.',item['localName'])
        item['localName']=item['localName'].replace('.layers.0.','.layers.4.')
        with self.assertRaisesRegex(ValueError,'sourceLoad'):
            self.check(rows)

    def test_closed_terminal_schema(self):
        rows=copy.deepcopy(self.rows);rows[0][1]['extra']=None
        with self.assertRaisesRegex(ValueError,'exact schema'):
            self.check(rows)


def negative(mutation):
    def test(self):
        rows=copy.deepcopy(self.rows);mutation(rows)
        with self.assertRaises(ValueError):self.check(rows)
    return test


for name,mutation in MUTATIONS.items():
    setattr(RankCut12Tests,'test_reject_'+name,negative(mutation))


class FileAndJSONTests(unittest.TestCase):
    def test_json_rejections_and_signed_zero(self):
        audit=adapter.core()
        with tempfile.TemporaryDirectory(prefix='cpu-rank12-parser-') as tmp:
            path=Path(tmp)/'record.jsonl'
            cases=[b'{"x":1,"x":2}\n{}\n',b'{"x":NaN}\n{}\n',b'[]\n{}\n',b'{}\n{}\n{}\n',
                b'{}\n',b'\xff\n{}\n',b'{"x":'+b'['*17+b'0'+b']'*17+b'}\n{}\n']
            for raw in cases:
                path.write_bytes(raw)
                with self.subTest(raw=raw[:25]),self.assertRaises(ValueError):audit.read_rows(path)
            path.write_bytes(b'{"x":-0}\n{}\n')
            rows,_=audit.read_rows(path)
            self.assertEqual(math.copysign(1,rows[0]['x']),-1)

    def test_bounded_regular_input(self):
        with tempfile.TemporaryDirectory(prefix='cpu-rank12-bounds-') as tmp:
            p=Path(tmp)/'input';p.write_bytes(b'12345')
            with self.assertRaises(ValueError):adapter.bounded(p,4)
            p.write_bytes(b'')
            with self.assertRaises(ValueError):adapter.bounded(p,4)
            p.write_bytes(b'1');link=Path(tmp)/'link';link.symlink_to(p)
            with self.assertRaises(ValueError):adapter.bounded(link,4)

    def test_file_inputs_distinct(self):
        with self.assertRaisesRegex(ValueError,'Distinct input'):
            adapter.validate([REFERENCE,REFERENCE],REFERENCE,EPOCH,PROMPT,TEACHER)

    def test_wrong_prompt_and_teacher_raw_pins(self):
        with tempfile.TemporaryDirectory(prefix='cpu-rank12-inputs-') as tmp:
            paths=[Path(tmp)/str(i) for i in range(5)]
            for p in paths:p.write_bytes(b'{}\n{}\n')
            with self.assertRaisesRegex(ValueError,'raw prompt'):
                adapter.validate(paths[:2],REFERENCE,EPOCH,paths[2],TEACHER)
            with self.assertRaisesRegex(ValueError,'raw teacher'):
                adapter.validate(paths[:2],REFERENCE,EPOCH,PROMPT,paths[2])

    def test_incomplete_stdout_rejected(self):
        with tempfile.TemporaryDirectory(prefix='cpu-rank12-incomplete-') as tmp:
            a,b=Path(tmp)/'a',Path(tmp)/'b';a.write_bytes(b'{}\n{}');b.write_bytes(b'{}\n{}\n')
            with self.assertRaisesRegex(ValueError,'Incomplete stdout'):
                adapter.validate([a,b],REFERENCE,EPOCH,PROMPT,TEACHER)


if __name__=='__main__':unittest.main()
