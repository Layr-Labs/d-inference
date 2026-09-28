"""Small metadata-only input retention checks; payload verifier is injected."""
import argparse
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch
from runtime.stage_checks import inputs
from runtime.stage_checks.common import canonical,digest
from stage_prefill_test_support import EPOCH,baseline,context


class PrefillInputTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No process/socket calls'));guard.start();self.addCleanup(guard.stop)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.base=Path(self.temp.name)
        self.model=self.base/'metadata';self.model.mkdir();self.ctx=context()
        text=dict(self.ctx['text'],vocab_size=8,max_position_embeddings=32768)
        config=canonical(dict(model_type='qwen3_5_text',**text));self.ctx['configuration_sha256']=digest(config)
        self.ctx['baseline_admission']['source']['sourceConfigurationSHA256']=digest(config)
        (self.model/'config.json').write_bytes(config)
        manifest=dict(aggregate_sha256=self.ctx['artifact'],total_size_bytes=len(config),
            files=[dict(path='config.json',sha256=digest(config))])
        (self.model/'manifest.json').write_bytes(canonical(manifest))
        self.prompt=self.base/'prompt.json';self.prompt.write_bytes(canonical(self.ctx['request']['promptTokenIDs']))
        _,raw,pin=baseline(self.ctx);self.baseline=self.base/'baseline.jsonl';self.baseline.write_bytes(raw)
        self.args=argparse.Namespace(command='prefill-ranks',model_dir=self.model,artifact_aggregate_sha256=self.ctx['artifact'],
            tokens_file=self.prompt,tokens_sha256=digest(self.prompt.read_bytes()),teacher_tokens_file=None,
            teacher_tokens_sha256=None,chunk_size=32,baseline_jsonl=self.baseline,baseline_sha256=digest(raw),
            baseline_evidence_sha256=pin,stage_prefill_policy='serial_v1',stage_logits_dtype='bfloat16')
        self.artifacts=Mock();self.artifacts.verify_model.return_value=None

    def prepare(self,name):
        output=self.base/name;output.mkdir()
        return inputs.prepare(self.args,output,EPOCH,self.artifacts),output

    def test_pinned_baseline_is_admitted_after_exact_metadata_retention(self):
        value,output=self.prepare('good')
        self.assertEqual(value['mode'],'prefill-ranks')
        self.assertEqual(value['baseline_admission']['evidence_sha256'],self.args.baseline_evidence_sha256)
        self.assertEqual((output/'inputs/baseline.jsonl').read_bytes(),self.baseline.read_bytes())
        self.artifacts.verify_model.assert_called_once_with(self.model.resolve(),self.ctx['artifact'])

    def test_baseline_wrong_pin_missing_pin_and_wrong_dtype_refuse(self):
        for name,value in [('baseline_sha256','0'*64),('baseline_evidence_sha256','0'*64),('stage_logits_dtype','float32')]:
            saved=getattr(self.args,name);setattr(self.args,name,value)
            with self.assertRaises(ValueError):self.prepare(name)
            setattr(self.args,name,saved)

    def test_valid_native_but_not_public_prompt64_is_refused(self):
        self.prompt.write_bytes(canonical([1]*64));self.args.tokens_sha256=digest(self.prompt.read_bytes())
        with self.assertRaisesRegex(ValueError,'65/32/1'):self.prepare('too-short')


if __name__=='__main__':unittest.main()
