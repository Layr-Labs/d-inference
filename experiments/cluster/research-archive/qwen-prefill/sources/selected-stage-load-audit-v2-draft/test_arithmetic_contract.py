import contextlib
import hashlib
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

import audit_selected_stage as audit
import selected_expected
from arithmetic_fixture import native_arithmetic_receipt
from test_inventory_audit import fabricated

ADDED_FIELDS = ('defaultBindings', 'actualProcessEnvironmentMustBePassedBeforeMLXInitialization',
    'sourceBinaryMetalLibraryAndHardwareIdentityStillRequired', 'sameChunkFullModelReferenceStillRequired',
    'doesNotValidateOtherTimingOrResourceEnvironment')


class ArithmeticContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = selected_expected.expected('registered_qwen35_9b')
    def setUp(self):
        self.guards = [patch('subprocess.Popen',side_effect=AssertionError('real process forbidden')),
            patch('subprocess.run',side_effect=AssertionError('real subprocess forbidden')),
            patch.object(socket,'socket',side_effect=AssertionError('network forbidden'))]
        for item in self.guards:item.start()
    def tearDown(self):
        for item in reversed(self.guards):item.stop()
    def replay(self, row):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'invented.jsonl'
            raw = json.dumps(row,separators=(',',':')).encode()+b'\n';path.write_bytes(raw)
            return audit.validate(path,hashlib.sha256(raw).hexdigest(),row['model'],row['stageIndex'])
    def test_actual_source_complete_dto_and_v1_omission(self):
        native = native_arithmetic_receipt()
        self.assertEqual(len(native),10)
        self.assertEqual(len(native['defaultBindings']),5)
        for stage in (0,1):
            row = fabricated(self.e,stage)
            self.assertEqual(row['arithmeticEnvironment'],native)
            self.assertTrue(self.replay(row)['passed'])
            row['arithmeticEnvironment'] = {k:v for k,v in native.items() if k not in ADDED_FIELDS}
            with self.assertRaisesRegex(ValueError,'Wrong metadata keys at arithmeticEnvironment'):
                self.replay(row)
    def test_missing_extra_and_wrong_default_binding(self):
        for field in ADDED_FIELDS:
            row=fabricated(self.e,0);del row['arithmeticEnvironment'][field]
            with self.subTest(missing=field),self.assertRaises(ValueError):self.replay(row)
        row=fabricated(self.e,0);row['arithmeticEnvironment']['unknown']=True
        with self.assertRaises(ValueError):self.replay(row)
        for key in native_arithmetic_receipt()['defaultBindings']:
            row=fabricated(self.e,0);row['arithmeticEnvironment']['defaultBindings'][key]+=' altered'
            with self.subTest(binding=key),self.assertRaises(ValueError):self.replay(row)
        row=fabricated(self.e,0);row['arithmeticEnvironment']['defaultBindings']['unknown']='extra'
        with self.assertRaises(ValueError):self.replay(row)
    def test_exact_boolean_and_integer_types(self):
        for field in ADDED_FIELDS[1:]:
            for value in (False,1,None,'true'):
                row=fabricated(self.e,0);row['arithmeticEnvironment'][field]=value
                with self.subTest(field=field,value=value),self.assertRaises(ValueError):self.replay(row)
        row=fabricated(self.e,0);row['arithmeticEnvironment']['full512TokenChunkQueryBlocks']=True
        with self.assertRaises(ValueError):self.replay(row)
    def test_arithmetic_failure_retains_new_receipt(self):
        row=fabricated(self.e,0);del row['arithmeticEnvironment']['defaultBindings']
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'invented.jsonl';out=Path(temp)/'failed.json'
            raw=json.dumps(row,separators=(',',':')).encode()+b'\n';path.write_bytes(raw)
            args=['--stdout',str(path),'--stdout-sha256',hashlib.sha256(raw).hexdigest(),
                '--profile',row['model'],'--stage-index','0','--output',str(out)]
            with contextlib.redirect_stdout(io.StringIO()):self.assertEqual(audit.main(args),1)
            receipt=json.loads(out.read_bytes());self.assertFalse(receipt['passed'])
            self.assertIn('Wrong metadata keys at arithmeticEnvironment',receipt['error'])
            self.assertFalse(receipt['tensorValuesReadOrCompared']);self.assertFalse(receipt['numericalParityEstablished'])
            saved=out.read_bytes()
            with self.assertRaises(ValueError):audit.main(args)
            self.assertEqual(out.read_bytes(),saved)


if __name__ == '__main__':unittest.main()
