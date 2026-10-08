"""Synthetic fixed-cut pair-origin and file-pin tests; no candidate outputs."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import audit_cut12_ranks as files
import cut12_rank_dependencies as dep
import cut12_rank_fixture as fixture
import qwen_long_prefill_rank_cut12_audit as audit


def qualified_fake_receipt(pair,prompt):
    # Execute the frozen CPU pair validator on synthetic files. Do not invent
    # its qualification result or borrow an unrelated real receipt.
    path=dep.PAIR/'audit_cut12_pair.py'
    module=dep.load_module('fixed_cut12_fake_pair_file_adapter',path,
        '376b3b4b56f675fddcca6be58e4a5af358ac353526ceb5c8a7ab2be8279a2c09')
    sys.path.insert(0,str(dep.PAIR))
    try: return module.validate(pair,prompt,hashlib.sha256(prompt.read_bytes()).hexdigest())
    finally: sys.path.remove(str(dep.PAIR))


class Cut12Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.x=fixture.fixture()

    def test_exact_selected_inventory_and_state(self):
        x=self.x;r=audit.check_rank_pair(x['ranks'],x['baseline'],x['prompt'],x['promptSHA'],x['epoch'],x['policy'])
        self.assertEqual(r['sourceInventory']['canonicalTensors'],927)
        self.assertEqual([len(z[1]['sourceLoad']['activeTensors']) for z in x['ranks']],[348,579])
        self.assertEqual([len(z[1]['execution']['finalDigest']['finalState']['entries']) for z in x['ranks']],[27,45])
        self.assertEqual([z[1]['execution']['finalDigest']['finalState']['logicalByteCount'] for z in x['ranks']],[119980044,199966740])
        self.assertEqual(r['completeFinalStateComponents'],72)

    def test_legacy_standalone_container_refused(self):
        x=self.x;reference=x['baseline'][0]['reference']
        fake=[{'kind':'qwen_long_prefill_reference_ready'}, {'kind':'qwen_long_prefill_reference_report','evidence':reference}]
        with self.assertRaises(ValueError):audit.check_rank_pair(x['ranks'],fake,x['prompt'],x['promptSHA'],x['epoch'],x['policy'])

    def test_coherent_old_half_pair_refused(self):
        old=dep.load_module('fake_half_pair_fixture',dep.ROOT/'long-prefill-pair-audit-draft/pair_fixture.py',
            'ebcee6ac8d1e34265b4105e7bbfbb45c2ac5ed51cbb78f5348b60ee92d1897a2')
        _,prompt,rows=old.fixture();x=self.x
        self.assertEqual(prompt,x['prompt'])
        with self.assertRaisesRegex(ValueError,'planSHA256'):
            audit.check_rank_pair(x['ranks'],rows,prompt,x['promptSHA'],x['epoch'],x['policy'])

    def test_corrupted_pair_candidate_blocks_reference_use(self):
        x=self.x;rows=copy.deepcopy(x['baseline'])
        rows[1]['comparison']['finalDigests'][0]['finalState']['entries'][0]['sha256']='0'*64
        with self.assertRaises(ValueError):audit.check_rank_pair(x['ranks'],rows,x['prompt'],x['promptSHA'],x['epoch'],x['policy'])

    def with_files(self, action):
        x=self.x;a=dep.context()[0]
        with tempfile.TemporaryDirectory(prefix='cut12-rank-fake-') as td:
            d=Path(td);paths=[d/'rank0.jsonl',d/'rank1.jsonl'];pair=d/'pair.jsonl';prompt=d/'prompt.json';receipt=d/'pair-cpu.json'
            for p,rows in zip(paths,x['ranks']):p.write_bytes(fixture.encoded(rows))
            pair.write_bytes(fixture.encoded(x['baseline']));prompt.write_bytes(x['prompt'])
            proof=qualified_fake_receipt(pair,prompt);receipt.write_text(json.dumps(proof,sort_keys=True)+'\n')
            args=[paths,pair,prompt,x['promptSHA'],x['epoch'],x['policy'],a.sha(pair.read_bytes()),receipt,a.sha(receipt.read_bytes())]
            action(args,proof)

    def test_file_api_qualified_synthetic_pair(self):
        def action(args,proof):
            result=files.validate(*args)
            self.assertTrue(result['sameCutPairContainerAndCPUReceiptValidated'])
            self.assertEqual(result['sourceLayerRanges'],[[0,12],[12,32]])
            self.assertEqual(result['stageStateComponents'],[27,45])
            self.assertFalse(result['oldStandaloneReferenceAccepted'])
            self.assertEqual(result['baselineReferenceFingerprint'],proof['referenceFingerprint'])
        self.with_files(action)

    def test_wrong_independent_pair_or_receipt_pin(self):
        def action(args,proof):
            for index in (6,8):
                changed=list(args);changed[index]='0'*64
                with self.assertRaises(ValueError):files.validate(*changed)
        self.with_files(action)

    def test_rehashed_wrong_qualification_result_is_refused(self):
        def action(args,proof):
            for field,value in [('status','failed'),('explicitStageCut',16),('helperSHA256','0'*64),('candidateNativeLogitBytesCompared',True)]:
                with self.subTest(field=field):
                    bad=copy.deepcopy(proof);bad[field]=value
                    args[7].write_text(json.dumps(bad,sort_keys=True)+'\n');changed=list(args)
                    changed[8]=hashlib.sha256(args[7].read_bytes()).hexdigest()
                    with self.assertRaises(ValueError):files.validate(*changed)
        self.with_files(action)

    def test_receipt_origin_paths_are_opaque_and_may_differ(self):
        def action(args,proof):
            proof['inputs'][0]['path']='/a/different/retained/pair/path'
            proof['inputs'][1]['path']='/a/different/retained/prompt/path'
            args[7].write_text(json.dumps(proof,sort_keys=True)+'\n')
            args[8]=hashlib.sha256(args[7].read_bytes()).hexdigest()
            self.assertTrue(files.validate(*args)['frozenInputsUnchanged'])
        self.with_files(action)

    def test_file_alias_truncation_and_mutation_refused(self):
        def action(args,proof):
            bad=list(args);bad[0]=[args[0][0],args[0][0]]
            with self.assertRaises(ValueError):files.validate(*bad)
            original=args[0][0].read_bytes();args[0][0].write_bytes(original[:-1])
            with self.assertRaises(ValueError):files.validate(*args)
            args[0][0].write_bytes(original)
            original_check=audit.check_rank_pair
            def changed(*values):
                result=original_check(*values);args[2].write_bytes(self.x['prompt']+b' ');return result
            with patch.object(audit,'check_rank_pair',side_effect=changed),self.assertRaisesRegex(ValueError,'changed during replay'):
                files.validate(*args)
        self.with_files(action)


if __name__=='__main__':unittest.main()
