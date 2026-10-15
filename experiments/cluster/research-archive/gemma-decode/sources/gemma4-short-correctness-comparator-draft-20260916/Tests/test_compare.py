"""Focused fabricated CPU fixtures. Source staged only until a root test grant."""
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from compare import compare
from fixtures import bundle,mutate_report,raw_json,replace_sidecar,sha
from recorded_math import logical_bytes,parse_json


class ComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=tempfile.TemporaryDirectory()
        cls.packet=bundle(Path(cls.base.name))

    @classmethod
    def tearDownClass(cls):cls.base.cleanup()

    def setUp(self):
        import shutil
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        source=Path(self.base.name);dest=Path(self.temp.name)
        for path in source.iterdir():
            if path.is_dir():shutil.copytree(path,dest/path.name)
            else:shutil.copyfile(path,dest/path.name)
        self.packet=json.loads(json.dumps(self.__class__.packet).replace(str(source),str(dest)))

    def refused(self,text=None):
        if text:
            with self.assertRaisesRegex(ValueError,text):compare(self.packet)
        else:
            with self.assertRaises((ValueError,FileNotFoundError)):compare(self.packet)

    def test_complete_mixed_type_rows_state_and_limited_scope(self):
        result=compare(self.packet)
        self.assertTrue(result['passed']);self.assertEqual(result['comparedStateEntries'],90)
        self.assertEqual(result['selectedTokenIDs'],[7,9]);self.assertEqual(result['fullVocabularyRows'],2)
        for key in ('physicalProcessOrLeaseRetirementEstablished','independentPhysicalResourceValidationEstablished',
                    'fullSourceOrBuildRevalidated','runtimeServingEnabled','encryptedRDMAEstablished'):
            self.assertIs(result[key],False)

    def test_signed_zero_difference_with_same_token_is_rejected(self):
        path=Path(self.packet['results']['stage1']['sidecarsDirectory'])/'row-0.json'
        row=json.loads(path.read_bytes());row['values'][0]=-0.0
        raw=bytearray(262144*2);raw[0:2]=b'\x00\x80';raw[14:16]=b'\x80\x3f'
        row['logicalBytesSHA256']=sha(raw)
        replace_sidecar(self.packet,'stage1','row-0.json',raw_json(row))
        self.refused('Full native row differs')

    def test_native_negative_zero_integer_spelling_is_preserved(self):
        record=dict(shape=[1,1],dtype='bfloat16',byteCount=2,logicalBytesSHA256=sha(b'\x00\x80'),values=[0])
        raw=raw_json(record).replace(b'"values":[0]',b'"values":[-0]')
        self.assertEqual(logical_bytes(parse_json(raw),1,'bfloat16'),b'\x00\x80')

    def test_truncated_vocabulary_row_is_rejected(self):
        path=Path(self.packet['results']['stage1']['sidecarsDirectory'])/'row-0.json'
        row=json.loads(path.read_bytes());row['values'].pop()
        replace_sidecar(self.packet,'stage1','row-0.json',raw_json(row));self.refused('Logit storage count')

    def test_wrong_argmax_tie_count_is_rejected(self):
        mutate_report(self.packet,'stage1',lambda r:r['execution']['rows'][0].update(maximumTieCount=2))
        self.refused('maximum tie count')

    def test_rehashed_state_mutation_is_rejected(self):
        path=Path(self.packet['results']['stage0']['sidecarsDirectory'])/'state-0-kv.keys.bin'
        raw=bytearray(path.read_bytes());raw[:2]=b'\x80\x3f'
        replace_sidecar(self.packet,'stage0',path.name,bytes(raw));self.refused('Stage0 native state differs')

    def test_rehashed_position_mutation_is_rejected(self):
        replace_sidecar(self.packet,'stage1','state-10-kv.position_offsets.bin',struct.pack('<i',32))
        self.refused('position frontier')

    def test_shifted_logical_range_is_rejected(self):
        mutate_report(self.packet,'stage0',lambda r:r['execution']['finalState']['entries'][0].update(logicalRange=[1,34]))
        self.refused('temporal shape')

    def test_duplicate_global_entry_is_rejected(self):
        mutate_report(self.packet,'stage1',lambda r:r['execution']['finalState']['entries'][3].update(globalLayerIndex=10))
        self.refused('global-local mapping')

    def test_unknown_actual_dtype_is_rejected(self):
        mutate_report(self.packet,'stage1',lambda r:r['execution']['binding']['layers'][0].update(dtype='BF16'))
        self.refused('Unknown actual KV dtype')

    def test_changed_peer_boundary_is_rejected(self):
        mutate_report(self.packet,'stage0',lambda r:r['execution']['frames'][1].update(boundarySHA256='1'*64))
        self.refused('peer boundary')

    def test_failed_full_reference_precedes_any_staged_path_access(self):
        mutate_report(self.packet,'full',lambda r:r.update(modelReleased=False))
        self.packet['results']['stage0']['report']['path']='/definitely-missing-gemma-candidate'
        self.refused('modelReleased')

    def test_stale_expected_scope_is_rejected(self):
        mutate_report(self.packet,'stage1',lambda r:r['expected'].update(membershipEpoch='00000000-0000-0000-0000-000000000000'))
        self.refused('prospective expected')

    def test_unreported_sidecar_is_rejected(self):
        (Path(self.packet['results']['full']['sidecarsDirectory'])/'unexpected.bin').write_bytes(b'x')
        self.refused('directory closure')

    def test_sidecar_symlink_is_rejected(self):
        directory=Path(self.packet['results']['full']['sidecarsDirectory']);file=directory/'state-0-kv.keys.bin'
        raw=file.read_bytes();file.unlink();external=directory.parent/'outside.bin';external.write_bytes(raw);file.symlink_to(external)
        self.refused('path kind')

    def test_native_failure_or_partial_retirement_is_rejected(self):
        mutate_report(self.packet,'stage0',lambda r:r['execution'].update(requestStateRetired=False))
        self.refused('requestStateRetired')

    def test_source_tensor_count_remains_complete_artifact(self):
        mutate_report(self.packet,'stage1',lambda r:r['execution']['sourceLoad'].update(sourceTensorCount=1339))
        self.refused('sourceTensorCount')

    def test_changed_report_bytes_fail_pin(self):
        path=Path(self.packet['results']['full']['report']['path']);path.write_bytes(path.read_bytes()+b' ')
        self.refused('Pinned input digest')


if __name__=='__main__':unittest.main()
