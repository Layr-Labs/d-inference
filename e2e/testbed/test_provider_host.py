"""CPU-only filesystem guards and harmless owned-child lifecycle tests."""
from pathlib import Path
import hashlib, json, os, signal, stat, subprocess, sys, tempfile, unittest
from unittest.mock import Mock, patch
import provider_host as host


def record(path):
    return {'sha256':host.digest(path),'bytes':path.stat().st_size,'mode':stat.S_IMODE(path.stat().st_mode)}


class HostGuards(unittest.TestCase):
    def test_absent_leaf_protected_alias_and_dangling_paths_refuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();home=root/'home';home.mkdir();protected=home/'.darkbloom';protected.mkdir()
            alias=root/'alias';alias.symlink_to(protected,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'protected'):host.canonical_owned_root(str(alias/'absent'),home)
            self.assertFalse((protected/'absent').exists())
            dangling=root/'dangling';dangling.symlink_to(root/'missing')
            for candidate in (dangling,dangling/'child'):
                with self.assertRaises((ValueError,FileNotFoundError)):host.canonical_owned_root(str(candidate),home)
            with self.assertRaises(ValueError):host.canonical_owned_root(str(root/'x/../run'),home)

    def test_modes_hashes_and_symlink_escape_refuse(self):
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary).resolve();path=root/'file';path.write_bytes(b'exact');expected=record(path)
            host.check_file(path,expected);path.write_bytes(b'wrong')
            with self.assertRaisesRegex(ValueError,'identity'):host.check_file(path,expected)
            path.write_bytes(b'exact');path.chmod(0o600 if expected['mode']!=0o600 else 0o644)
            with self.assertRaisesRegex(ValueError,'identity'):host.check_file(path,expected)
            sub=root/'sub';sub.mkdir();(sub/'escape').symlink_to(path)
            with self.assertRaisesRegex(ValueError,'escapes'):host.safe_file(sub,'escape')
            with self.assertRaises(ValueError):host.safe_file(sub,'../file')

    def test_process_paths_with_spaces_are_detected_and_owned_pid_excluded(self):
        def output(argv,**_):
            if argv[0]=='ps':
                return '101 /fixture path with spaces/darkbloom\n202 /owned path/darkbloom\n303 /unrelated process/python3\n'
            if argv[0]=='/fixture/macmon':
                return '{"temp":{"gpu_temp_avg":30}}\n'
            if argv[-1]=='hw.model':return 'MacFixture,1\n'
            if argv[-1]=='hw.memsize':return str(36<<30)+'\n'
            raise AssertionError('unexpected subprocess '+repr(argv))
        with patch.object(host.subprocess,'check_output',side_effect=output),patch.object(host,'check_file'),patch.object(host.os,'getloadavg',return_value=(1,1,1)),patch.object(host.shutil,'disk_usage',return_value=Mock(free=200<<30)):
            observed=host.observe({'macmon_path':'/fixture/macmon','macmon':{}},owned=(202,))
        self.assertEqual(observed['unexpected_processes'],[101])
        self.assertEqual(observed['owned_processes'],[202])

    def test_entry_rejects_heat_nonfinite_and_leftovers(self):
        value={'unexpected_processes':[],'owned_processes':[],'gpu_temperature_c':30,'load1':1,'free_bytes':200<<30}
        host.require_entry(value)
        for delta in ({'gpu_temperature_c':55},{'gpu_temperature_c':float('nan')},{'owned_processes':[123]},{'free_bytes':1}):
            with self.assertRaises(ValueError):host.require_entry({**value,**delta})

    def fixture(self,root):
        home=root/'home';home.mkdir();config=home/'.config/darkbloom/provider.toml';config.parent.mkdir(parents=True);config.write_bytes(b'existing')
        source=root/'source';source.mkdir();binary=source/'darkbloom';binary.write_bytes(b'never executed');binary.chmod(0o755)
        metal=source/'mlx.metallib';metal.write_bytes(b'fixture')
        target={'root':str(root/'fresh'),'runtime_directory':str(source),'runtime_files':{'darkbloom':record(binary),'mlx.metallib':record(metal)},
                'canonical_config_sha256':host.digest(config),'hardware_model':'MacFixture,1','memory_bytes':36<<30,'models':[]}
        request={'target':target,'spec':{'root':target['root'],'config':'owned'},'suite_nonce':'nonce','auth_token':'Zml4dHVyZS10b2tlbg=='}
        observation={'hardware_model':'MacFixture,1','memory_bytes':36<<30,'gpu_temperature_c':30,'load1':1,'free_bytes':200<<30,'unexpected_processes':[],'owned_processes':[]}
        return home,request,observation

    def test_preparation_stages_exact_runtime_and_private_token(self):
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary).resolve();home,request,observation=self.fixture(root)
            with patch.object(host.Path,'home',return_value=home),patch.object(host.subprocess,'run',return_value=Mock(returncode=0,stdout=b'')),patch.object(host.subprocess,'check_output',return_value='"IOPlatformUUID" = "fixture"'),patch.object(host,'verify_models'),patch.object(host,'observe',return_value=observation):
                created,canonical,identity,_=host.prepare(request)
            self.assertEqual((created/'auth_token').read_bytes(),b'fixture-token')
            self.assertEqual(stat.S_IMODE((created/'auth_token').stat().st_mode),0o600)
            self.assertEqual((created/'runtime/darkbloom').read_bytes(),(root/'source/darkbloom').read_bytes())
            self.assertEqual(host.digest(canonical),request['target']['canonical_config_sha256'])
            self.assertEqual(identity,hashlib.sha256(b'noncefixture').hexdigest())

    def test_owned_root_cannot_be_created_inside_direct_model_input(self):
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary).resolve();home,request,_=self.fixture(root)
            model=root/'model';model.mkdir()
            request['target']['models']=[{'snapshot':str(model)}]
            request['target']['root']=request['spec']['root']=str(model/'new-owned-root')
            with patch.object(host.Path,'home',return_value=home),patch.object(host.subprocess,'run',return_value=Mock(returncode=0,stdout=b'')),patch.object(host,'observe')as observe:
                with self.assertRaisesRegex(ValueError,'overlaps selected model'):host.prepare(request)
                observe.assert_not_called()
            self.assertEqual(list(model.iterdir()),[])

    def test_wrong_runtime_or_entitlement_refuses_before_root_creation(self):
        for fault in ('hash','entitled'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory()as temporary:
                root=Path(temporary).resolve();home,request,_=self.fixture(root)
                if fault=='hash':request['target']['runtime_files']['darkbloom']['sha256']='0'*64
                with patch.object(host.Path,'home',return_value=home),patch.object(host.subprocess,'run',return_value=Mock(returncode=0,stdout=b'keychain-access-groups'))as codecheck,patch.object(host,'observe')as observe,patch.object(host,'verify_models')as models:
                    with self.assertRaises(ValueError):host.prepare(request)
                    if fault=='hash':codecheck.assert_not_called()
                    observe.assert_not_called();models.assert_not_called()
                self.assertFalse(Path(request['target']['root']).exists())

    def test_model_snapshot_selection_and_full_manifest(self):
        with tempfile.TemporaryDirectory()as temporary:
            home=Path(temporary).resolve();parent=home/'.cache/huggingface/hub/models--org--model/snapshots';parent.mkdir(parents=True)
            snapshot=parent/'exact';snapshot.mkdir();file=snapshot/'weights';file.write_bytes(b'weights')
            target={'models':[{'id':'org/model','snapshot':str(snapshot),'files':{'weights':record(file)}}]}
            host.verify_models(target,home)
            newer=parent/'newer';newer.mkdir();os.utime(newer,(file.stat().st_mtime+10,)*2)
            with self.assertRaisesRegex(ValueError,'resolution'):host.verify_models(target,home)
            newer.rmdir();file.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'identity'):host.verify_models(target,home)

    def test_standard_hf_blob_symlink_is_bounded_and_runtime_remains_strict(self):
        with tempfile.TemporaryDirectory()as temporary:
            home=Path(temporary).resolve();model=home/'.cache/huggingface/hub/models--org--model'
            snapshot=model/'snapshots/exact';snapshot.mkdir(parents=True);blobs=model/'blobs';blobs.mkdir()
            blob=blobs/'hash';blob.write_bytes(b'weights');file=snapshot/'weights';file.symlink_to(blob)
            target={'models':[{'id':'org/model','snapshot':str(snapshot),'files':{'weights':record(blob)}}]}
            host.verify_models(target,home)
            with self.assertRaisesRegex(ValueError,'regular'):host.check_file(file,record(blob))
            outside=home/'outside';outside.write_bytes(b'weights');file.unlink();file.symlink_to(outside)
            with self.assertRaisesRegex(ValueError,'escapes'):host.verify_models(target,home)

    def test_direct_assistant_manifest_is_verified_without_hf_substitution(self):
        with tempfile.TemporaryDirectory()as temporary:
            home=Path(temporary).resolve();assistant=home/'assistant';assistant.mkdir();file=assistant/'weights';file.write_bytes(b'assistant')
            target={'assistant_path':str(assistant),'models':[{'id':'assistant','snapshot':str(assistant),'files':{'weights':record(file)}}]}
            host.verify_models(target,home);file.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'identity'):host.verify_models(target,home)


class OwnedLifecycle(unittest.TestCase):
    def run_case(self,operation,lease=5,deadline=5,cleanup_failure=False):
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary).resolve()
            setup=""
            if cleanup_failure:
                setup="original=h.retire_group\ndef broken(process,record):\n original(process,record)\n raise RuntimeError('planted cleanup receipt fault')\nh.retire_group=broken\n"
            code="import sys;from pathlib import Path;sys.path.insert(0,"+repr(str(Path(host.__file__).parent))+");import provider_host as h\n"+setup+"r=h.run_owner([sys.executable,'-c','import time;time.sleep(300)'],dict(__import__('os').environ),Path("+repr(str(root))+"),sys.stdin.buffer,h.send,lease_seconds="+str(lease)+",deadline_seconds="+str(deadline)+");sys.exit(0 if r['failure'] is None else 2)"
            owner=subprocess.Popen([sys.executable,'-u','-c',code],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            child=None
            try:
                started=json.loads(owner.stdout.readline());self.assertEqual(started['event'],'started');child=started['pid']
                operation(owner,root)
                stdout,stderr=owner.communicate(timeout=5)
                self.assertTrue((root/'terminal.json').is_file(),stderr)
                receipt=json.loads((root/'terminal.json').read_text());self.assertEqual(receipt['pid'],child);self.assertIsNotNone(receipt['exit_code'])
                self.assertEqual(receipt['group_cleanup_complete'],not cleanup_failure,receipt)
                with self.assertRaises(ProcessLookupError):os.kill(child,0)
                self.assertIn('terminal',stdout)
                return receipt,owner.returncode
            finally:
                if owner.poll()is None:owner.kill();owner.wait(timeout=5)
                if child is not None:
                    try:os.killpg(child,signal.SIGKILL)
                    except ProcessLookupError:
                        # The owner may already have reaped the descendant.
                        pass

    def test_stop_reaps_child(self):
        def stop(owner,_):owner.stdin.write('{"command":"stop"}\n');owner.stdin.flush()
        row,code=self.run_case(stop);self.assertEqual(code,0);self.assertTrue(row['stop_requested']);self.assertIsNone(row['failure'])

    def test_cleanup_exception_retains_incomplete_terminal_receipt(self):
        def stop(owner,_):owner.stdin.write('{"command":"stop"}\n');owner.stdin.flush()
        row,code=self.run_case(stop,cleanup_failure=True)
        self.assertEqual(code,2)
        self.assertIn('planted cleanup receipt fault',row['failure'])

    def test_eof_reaps_child(self):
        def eof(owner,_):owner.stdin.close();owner.stdin=None
        row,code=self.run_case(eof);self.assertEqual(code,2);self.assertIn('pipe EOF',row['failure'])

    def test_lease_and_deadline_reap_with_open_control_pipe(self):
        def wait(owner,_):owner.wait(timeout=4)
        for lease,deadline,reason in ((0.2,5,'lease'),(5,0.2,'deadline')):
            with self.subTest(reason=reason):
                row,code=self.run_case(wait,lease,deadline);self.assertEqual(code,2);self.assertIn(reason,row['failure'])

    def test_hup_and_term_reap_with_terminal_receipt(self):
        for sig in (signal.SIGHUP,signal.SIGTERM):
            with self.subTest(signal=sig):
                row,code=self.run_case(lambda owner,_:owner.send_signal(sig));self.assertEqual(code,2);self.assertIn('owner signal',row['failure'])

    def test_missing_state_then_valid_state_uses_same_child(self):
        def ask(owner,root):
            owner.stdin.write('{"command":"state","id":1}\n');owner.stdin.flush()
            first=json.loads(owner.stdout.readline());self.assertEqual(first['error'],'not_ready');self.assertEqual(first['id'],1)
            (root/'daemon-state.json').write_text('{"ready":true}')
            owner.stdin.write('{"command":"state","id":2}\n');owner.stdin.flush()
            second=json.loads(owner.stdout.readline());self.assertEqual(second['id'],2);self.assertIn('body',second)
            owner.stdin.write('{"command":"stop"}\n');owner.stdin.flush()
        row,code=self.run_case(ask);self.assertEqual(code,0);self.assertTrue(row['stop_requested'])

    def test_exited_leader_does_not_leave_its_owned_sleeper(self):
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary).resolve();pidfile=root/'descendant.pid'
            leader="import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(300)']);Path("+repr(str(pidfile))+").write_text(str(p.pid))"
            command=[sys.executable,'-c',leader]
            code="import sys;from pathlib import Path;sys.path.insert(0,"+repr(str(Path(host.__file__).parent))+");import provider_host as h;h.run_owner("+repr(command)+",dict(__import__('os').environ),Path("+repr(str(root))+"),sys.stdin.buffer,h.send)"
            owner=subprocess.Popen([sys.executable,'-u','-c',code],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            descendant=None
            try:
                started=json.loads(owner.stdout.readline());self.assertEqual(started['event'],'started')
                owner.wait(timeout=5)
                descendant=int(pidfile.read_text())
                receipt=json.loads((root/'terminal.json').read_text())
                self.assertEqual(receipt['exit_code'],0)
                self.assertTrue(receipt['group_cleanup_complete'])
                with self.assertRaises(ProcessLookupError):os.kill(descendant,0)
                self.assertIn(signal.SIGTERM,receipt['signals_sent'])
            finally:
                if owner.poll()is None:owner.kill();owner.wait(timeout=5)
                if descendant is not None:
                    try:os.kill(descendant,signal.SIGKILL)
                    except ProcessLookupError:pass
                owner.stdin.close();owner.stdout.close();owner.stderr.close()

    def test_state_symlink_escape_refuses_and_reaps(self):
        def ask(owner,root):
            external=root.parent/(root.name+'-external');external.write_bytes(b'private fixture');self.addCleanup(external.unlink)
            (root/'daemon-state.json').symlink_to(external)
            owner.stdin.write('{"command":"state","id":1}\n');owner.stdin.flush();owner.wait(timeout=4)
        row,code=self.run_case(ask);self.assertEqual(code,2);self.assertIn('OSError',row['failure'])


if __name__=='__main__':unittest.main()
