"""Invented metadata and temporary files only; no actual candidate or fixture reads."""
import ast
import copy
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import audit_dense_constructor_metadata_v2 as oracle


def integer_record():
    parameter = dict(shape=[1, 2], logicalByteCount=8)
    constructor = dict(layerCount=1, logicalParameterBytes=8, parameters=[parameter])
    tensor = dict(shape=[1, 2], byteCount=8)
    stage = dict(constructor=copy.deepcopy(constructor), expectedActiveTensors=[copy.deepcopy(tensor)],
        installedLazyInertModules=[dict(parameters=[copy.deepcopy(tensor)])],
        expectedPostLoadSummary=dict(stageIndex=0, loadedTensorBytes=8, activeTensorCount=1,
                                    inertTensorBytes=8, inertTensorCount=1))
    return dict(schemaVersion=1, sourceTensorCount=1, sourceTensorBytes=8, largestSourceTensorBytes=8,
        fullCheckpointVerificationPasses=1, constructorsInspected=3,
        arithmeticEnvironment=dict(full512TokenChunkQueryBlocks=4),
        sourceTensors=[dict(tensor, offset=8)], fullConstructor=constructor, stages=[stage])


class Tests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.fixture = self.root/'invented-fixture.json'
        self.fixture.write_bytes(b'{}\n')
        self.stdout = self.root/'invented-stdout.jsonl'
        self.stdout.write_bytes(b'{}\n')
        for guard in [patch.object(oracle, 'FIXTURE', self.fixture),
                      patch.object(oracle, 'FIXTURE_SHA', oracle.sha(self.fixture.read_bytes())),
                      patch('subprocess.run', side_effect=AssertionError('Subprocess forbidden')),
                      patch('subprocess.Popen', side_effect=AssertionError('Native forbidden')),
                      patch('socket.socket', side_effect=AssertionError('Socket forbidden'))]:
            guard.start(); self.addCleanup(guard.stop)

    def test_valid_integer_metadata_gate(self):
        oracle.require_integer_metadata(integer_record())

    def test_boolean_integer_refusals_cover_every_int_field(self):
        original = integer_record()
        paths = []
        def walk(value, path=()):
            if type(value) is dict:
                for key, item in value.items(): walk(item, path+(key,))
            elif type(value) is list:
                for index, item in enumerate(value): walk(item, path+(index,))
            elif type(value) is int: paths.append(path)
        walk(original)
        self.assertEqual(len(paths),32)
        for path in paths:
            with self.subTest(path=path):
                value=copy.deepcopy(original); cursor=value
                for key in path[:-1]: cursor=cursor[key]
                cursor[path[-1]]=False if cursor[path[-1]]==0 else True
                with self.assertRaisesRegex(ValueError,'Expected integer'):
                    oracle.require_integer_metadata(value)

    def test_noninteger_shape_and_byte_refused(self):
        value=integer_record(); value['stages'][0]['expectedActiveTensors'][0]['shape'][0]='1'
        with self.assertRaises(ValueError):oracle.require_integer_metadata(value)
        value=integer_record();value['fullConstructor']['parameters'][0]['logicalByteCount']=8.0
        with self.assertRaises(ValueError):oracle.require_integer_metadata(value)

    def test_integer_gate_precedes_original_comparisons(self):
        value=integer_record(); value['schemaVersion']=True
        with self.assertRaisesRegex(ValueError,'report.schemaVersion'):
            oracle.audit(value,{})

    def test_scalar_failure_receipt_preserves_input(self):
        value=integer_record();value['stages'][0]['expectedPostLoadSummary']['inertTensorCount']=True
        raw=json.dumps(value).encode()+b'\n';self.stdout.write_bytes(raw)
        output=self.root/'failure.json'
        result=oracle.audit_files(self.stdout,output)
        self.assertFalse(result['passed']);self.assertEqual(result['status'],'failed')
        self.assertEqual(result['primaryFailure']['type'],'ValueError')
        self.assertIn('inertTensorCount',result['primaryFailure']['message'])
        self.assertEqual(result['stdoutSHA256'],oracle.sha(raw))
        self.assertEqual(self.stdout.read_bytes(),raw)
        self.assertEqual(json.loads(output.read_bytes()),result)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode),0o600)

    def test_decode_failure_receipt_and_existing_output_refusal(self):
        raw=b'{"x":1,"x":2}\n';self.stdout.write_bytes(raw)
        output=self.root/'failure.json'; result=oracle.audit_files(self.stdout,output)
        self.assertFalse(result['passed']);self.assertIn('Duplicate',result['primaryFailure']['message'])
        saved=output.read_bytes()
        with self.assertRaises(FileExistsError):oracle.audit_files(self.stdout,output)
        self.assertEqual(output.read_bytes(),saved);self.assertEqual(self.stdout.read_bytes(),raw)

    def test_success_publication_only_fake_comparison(self):
        # Publication test only: this deliberately does not qualify metadata comparisons.
        fake=dict(passed=True,modelNumericsQualified=False,performanceQualified=False)
        with patch.object(oracle,'audit',return_value=fake) as check:
            result=oracle.audit_files(self.stdout,self.root/'success.json')
        check.assert_called_once_with({},{})
        self.assertTrue(result['passed']);self.assertEqual(result['status'],'passed')
        self.assertIsNone(result['primaryFailure'])

    def test_cli_returns_failure_after_retaining_receipt(self):
        output=self.root/'failure.json'
        with patch('sys.argv',['audit','--stdout',str(self.stdout),'--output',str(output)]),patch('builtins.print'):
            status=oracle.main()
        self.assertEqual(status,1);self.assertFalse(json.loads(output.read_bytes())['passed'])

    def test_original_comparison_ast_unchanged_after_single_guard(self):
        root=Path(__file__).parent
        before=ast.parse((root/'originals/audit-dense-constructor-metadata-20260914.py').read_text())
        after=ast.parse((root/'audit_dense_constructor_metadata_v2.py').read_text())
        old={n.name:n for n in before.body if isinstance(n,ast.FunctionDef)}
        new={n.name:n for n in after.body if isinstance(n,ast.FunctionDef)}
        for name in old.keys()-{'main'}:
            current=copy.deepcopy(new[name])
            if name=='audit':
                self.assertEqual(ast.unparse(current.body[0]),'require_integer_metadata(report)')
                current.body=current.body[1:]
            self.assertEqual(ast.dump(old[name]),ast.dump(current),name)


if __name__=='__main__':unittest.main()
