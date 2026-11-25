import copy
import unittest
import subprocess
import sys
import tempfile
from pathlib import Path
from derive_identity import derive, load_inputs
from recorded_math import canonical, digest


class IdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.values, _ = load_inputs()

    def test_exact_prior_constructor_and_current_metadata_join(self):
        value=derive(self.values)
        self.assertEqual(value['arithmeticSHA256'],'0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74')
        self.assertEqual(value['storageCommitment']['canonicalTensorCount'],1847)
        self.assertEqual([s['activeTensorCount'] for s in value['storageCommitment']['stages']],[923,924])
        self.assertFalse(value['candidateGenerationDataRead']);self.assertFalse(value['actualLoadedInventoryEstablished'])

    def test_wrong_plan_construction_mapping_and_incomplete_prior_run(self):
        changes=[lambda x:x['recording-metadata.json'].__setitem__('planSHA256','0'*64),
            lambda x:x['recording-metadata.json']['constructionConfigurationSHA256'].__setitem__(1,'0'*64),
            lambda x:x['constructor.stdout.jsonl']['sourceTensors'][0].__setitem__('offset',1),
            lambda x:x['constructor.stdout.jsonl']['stages'][1]['expectedActiveTensors'].pop(),
            lambda x:x['constructor-receipt.json'].__setitem__('nativeReaped',False),
            lambda x:x['constructor.stdout.jsonl'].__setitem__('forwardExecuted',True)]
        for change in changes:
            values=copy.deepcopy(self.values);change(values)
            with self.assertRaises((ValueError,KeyError)):derive(values)

    def test_actual_cli_rechecks_inputs_and_refuses_output_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'expected.json'
            command=[sys.executable,'-B',str(Path(__file__).with_name('derive_identity.py')),'--output',str(output)]
            result=subprocess.run(command,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            self.assertEqual(output.read_bytes(),canonical(derive(self.values))+b'\n')
            self.assertEqual(output.stat().st_mode & 0o777,0o600)
            again=subprocess.run(command,capture_output=True,timeout=10)
            self.assertNotEqual(again.returncode,0)
            self.assertEqual(output.read_bytes(),canonical(derive(self.values))+b'\n')

    def test_declared_owner_arithmetic_is_exact_and_empty_is_not_absent(self):
        for name,value in [('DARKBLOOM_BF16_WEIGHTS','0'),('MLX_ENABLE_TF32',''),('MLX_METAL_GPU_ARCH','')]:
            data=copy.deepcopy(self.values);data['owner-rank1.json']['workerEnvironment'][name]=value
            with self.subTest(name=name),self.assertRaises(ValueError):derive(data)


if __name__=='__main__':unittest.main()
