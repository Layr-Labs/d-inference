"""Actual prospective CLI checks using only pinned prompt/metadata, no candidate files."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
FROZEN = ROOT/'registered-generation-numerical-audit-draft-20260915'
IDENTITY = ROOT/'qwen27b-expected-generation-identity-20260915'
INPUT = ROOT/'qwen27b-short-generation-input-20260915'
EPOCH = '93604d14-37da-4e80-ad11-9ddf9ff48d1e'


def command(output, original=False):
    identity = json.loads((IDENTITY/'expected-identity.json').read_bytes())
    args = [sys.executable,'-B',str(BASE/('original' if original else 'proposed')/'prepare_expected.py')]
    for name,path in [('request',INPUT/'request.json'),('plan',IDENTITY/'inputs/recording-metadata.json'),('prompt',INPUT/'prompt.ids.json')]:
        args += ['--'+name,str(path),'--'+name+'-sha256',hashlib.sha256(path.read_bytes()).hexdigest()]
    return args + ['--epoch',EPOCH,'--storage-commitment-sha256',identity['storageCommitmentSHA256'],
        '--numerical-policy-sha256',identity['arithmeticSHA256'],'--output',str(output)]


def run(args):
    environment=dict(os.environ, PYTHONPATH=str(FROZEN))
    return subprocess.run(args,capture_output=True,timeout=10,env=environment)


class CLI(unittest.TestCase):
    def test_original_refuses_known_unchanged_inputs(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'expected.json';r=run(command(out,True))
            self.assertNotEqual(r.returncode,0);self.assertIn(b'input recheck',r.stderr);self.assertFalse(out.exists())

    def test_corrected_cli_publishes_exact_expected_agreement(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'expected.json';r=run(command(out))
            self.assertEqual(r.returncode,0,r.stderr.decode())
            self.assertEqual(out.stat().st_mode & 0o777,0o600)
            expected=json.loads(out.read_bytes())
            self.assertEqual(expected['membershipEpoch'],EPOCH)
            self.assertEqual(expected['requestID'],'20801ced-ca29-4faf-b71a-9ebbe1886a14')
            self.assertEqual(expected['storageCommitmentSHA256'],'c72e2c72815e76f522bc6d25e051750c774a101f47278bebb0103f46800968ce')
            self.assertEqual(expected['rankBuildSHA256'],['a7c35b37c2ae2f80c320221ac9931bdd3f87d7e7cd67b2d5cfbc93a8eb043ad6']*2)
            self.assertFalse(expected['mtpEnabled'])

    def test_wrong_input_pin_refused_without_output(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'expected.json';args=command(out);args[args.index('--prompt-sha256')+1]='0'*64
            r=run(args);self.assertNotEqual(r.returncode,0);self.assertFalse(out.exists())

    def test_output_not_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'expected.json';out.write_bytes(b'preserve')
            r=run(command(out));self.assertNotEqual(r.returncode,0);self.assertEqual(out.read_bytes(),b'preserve')


if __name__=='__main__':unittest.main()
