"""Execute only pinned-control pure file paths with fabricated metadata and fakes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from long_rank_configuration import configuration,REQUIRED_ENVIRONMENT
from long_rank_client import collect_metadata
from long_rank_test_support import EPOCH,ENDPOINTS,INPUTS,RAW_PROMPT,RAW_TEACHER


class Tests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.root=Path(temporary.name)
        for name in ('subprocess.run','subprocess.Popen','socket.socket'):
            guard=patch(name,side_effect=AssertionError('Actual process/socket forbidden'));guard.start();self.addCleanup(guard.stop)
        self.sha=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()

    def setup_controls(self):
        bundle=self.root/'bundle';bundle.mkdir();model=self.root/'fabricated-model-metadata';model.mkdir()
        (self.root/'metadata').mkdir();(bundle/'cluster-inference').write_bytes(b'not executable')
        (bundle/'bundle.json').write_text(json.dumps(dict(files=[])))
        (model/'config.json').write_bytes(b'{}');(model/'manifest.json').write_bytes(b'{}')
        config=dict(run=str(self.root),bundle=str(bundle),model=str(model),ranks=[],hostfile=ENDPOINTS,
            bundle_sha256=self.sha(bundle/'bundle.json'),binary_sha256=self.sha(bundle/'cluster-inference'),
            configuration_sha256=self.sha(model/'config.json'),artifact_sha256='a'*64)
        for index in (0,1):
            directory=self.root/('rank-'+str(index));directory.mkdir()
            rank=configuration(bundle,config['bundle_sha256'],model,INPUTS['prompt_file_sha256'],INPUTS['teacher_file_sha256'],index,EPOCH)
            (directory/'rank.json').write_text(json.dumps(rank))
            (directory/'prompt.json').write_bytes(RAW_PROMPT);(directory/'teacher.json').write_bytes(RAW_TEACHER)
            (directory/'hosts.json').write_bytes(json.dumps(ENDPOINTS).encode())
            config['ranks'].append(dict(rank=index,directory=str(directory),rank_sha256=self.sha(directory/'rank.json'),
                prompt_sha256=self.sha(directory/'prompt.json'),prompt_size_bytes=len(RAW_PROMPT),
                teacher_sha256=self.sha(directory/'teacher.json'),teacher_size_bytes=len(RAW_TEACHER),
                hostfile_sha256=self.sha(directory/'hosts.json'),hostfile_size_bytes=(directory/'hosts.json').stat().st_size,
                required_environment=dict(REQUIRED_ENVIRONMENT,MLX_RANK=str(index))))
        calls=[];fake=SimpleNamespace(file_sha256=self.sha,
            verify_files=lambda *args:{'cluster-inference':config['binary_sha256']},
            verify_model=lambda *args:calls.append(args) or 'a'*64)
        with patch.dict(sys.modules,{'artifacts':fake}):
            spec=importlib.util.spec_from_file_location('short_rank_fake_control',Path(__file__).with_name('long_rank_control.py'))
            control=importlib.util.module_from_spec(spec);spec.loader.exec_module(control)
        return config,control,calls

    def test_both_rank_teacher_files_are_verified_before_and_after(self):
        config,control,calls=self.setup_controls()
        with patch.object(control,'observation',return_value={'fake':True}),patch.object(control,'resource_preflight',return_value={'passed':True}):
            before=control.verify_and_record(config,'before');after=control.verify_and_record(config,'after')
            self.assertEqual(len(calls),2)
            for result in (before,after):
                self.assertEqual([r['rank'] for r in result['ranks']],[0,1])
                for rank in result['ranks']:
                    self.assertEqual(rank['teacher_sha256'],INPUTS['teacher_file_sha256']);self.assertEqual(rank['teacher_size_bytes'],len(RAW_TEACHER))
                    self.assertFalse(rank['raw_prompt_reencoded']);self.assertFalse(rank['raw_teacher_reencoded'])
            for index in (0,1):
                path=self.root/('rank-'+str(index))/'teacher.json';self.assertEqual(path.stat().st_mode&0o777,0o400)
                path.chmod(0o600);path.write_bytes(b'[1,2,3]')
                for phase in ('before','after'):
                    with self.assertRaisesRegex(ValueError,'Remote raw rank input changed'):control.verify_and_record(config,phase)
                path.write_bytes(RAW_TEACHER)
            self.assertEqual(len(calls),2)

    def test_both_actual_rank_teacher_files_are_retrieved_and_hash_checked(self):
        config,control,_=self.setup_controls()
        with patch.object(control,'observation',return_value={'fake':True}),patch.object(control,'resource_preflight',return_value={'passed':True}):
            before=control.verify_and_record(config,'before');after=control.verify_and_record(config,'after')
        layout=dict(run=str(self.root),rank_directories=[r['directory'] for r in config['ranks']]);requests=[]
        def scp(source,target):
            requests.append(source);path=Path(shlex.split(source.split(':',1)[1])[0]);shutil.copyfile(path,target)
        output=self.root/'retrieved';output.mkdir()
        records=collect_metadata(SimpleNamespace(scp=scp),'fixture-peer',layout,before,after,output)
        self.assertEqual(len(records),12)
        for rank in (0,1):
            path=output/'remote-metadata'/('rank-'+str(rank)+'-teacher.json')
            self.assertEqual(path.read_bytes(),RAW_TEACHER)
            self.assertEqual(self.sha(path),INPUTS['teacher_file_sha256'])
            self.assertIn('fixture-peer:'+str(self.root/('rank-'+str(rank))/'teacher.json'),requests)


if __name__=='__main__':unittest.main()
