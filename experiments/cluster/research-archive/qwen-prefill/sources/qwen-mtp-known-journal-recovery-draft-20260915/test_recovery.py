"""Temporary-file and local owned-child checks; never touches the canonical user device lease."""
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from recovery_contract import CASES, CONTROLLER_SHA, evidence, known_journal
from recovery_files import RecoveryRefusal, HeldJournal, DurableBackup
from recovery_processes import observe, parse_processes, NATIVE_OR_OWNER_NAMES
from recover_known_mtp_journal import recover

BASE = Path(__file__).resolve().parent


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.directory = self.base / 'device'; self.directory.mkdir(mode=0o700)
        self.file = self.directory / 'native-device.lease'
        self.journal, self.evidence = evidence(BASE / 'evidence', 0, CASES[0]['peerID'],
                                               CASES[0]['sha256'], CONTROLLER_SHA)
        self.original = self.evidence['rank0-journal.json']
        self.file.write_bytes(self.original); self.file.chmod(0o600)
        self.samples = []

    def quiet(self, until):
        # The observer runs while the exact canonical inode is exclusively held.
        with self.file.open('r+b') as stream:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sample = dict(prohibited=[], processCount=3, observedStartMonotonicNS=time.monotonic_ns(),
                      observedEndMonotonicNS=time.monotonic_ns(), stdoutSHA256='0'*64)
        self.samples.append(sample)
        return sample

    def run_recovery(self, observer=None):
        return recover(self.directory, self.journal, self.evidence, time.monotonic()+10, observer or self.quiet)

    def unchanged(self, result):
        self.assertFalse(result['cleared']); self.assertIn('error', result)
        self.assertEqual(self.file.read_bytes(), self.original)
        self.assertFalse(result['truncateAttempted'])

    def test_success_retains_inode_exact_durable_backup_and_separate_outcome(self):
        before = self.file.stat()
        result = self.run_recovery()
        self.assertTrue(result['cleared']); self.assertTrue(result['emptyReadback'])
        self.assertFalse(result['protocolReleaseAcknowledged']); self.assertTrue(result['failedRunRemainsFailed'])
        self.assertEqual((before.st_dev,before.st_ino),(self.file.stat().st_dev,self.file.stat().st_ino))
        self.assertEqual(self.file.read_bytes(), b''); self.assertEqual(len(self.samples), 2)
        backup = Path(result['backupDirectory'])
        self.assertEqual((backup/'journal.before.json').read_bytes(), self.original)
        for name, raw in self.evidence.items():
            self.assertEqual((backup/('evidence-'+name)).read_bytes(), raw)
        for file in backup.iterdir(): self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
        self.assertTrue(json.loads((backup/'administrative-result.json').read_text())['cleared'])
        # Administrative success is one-shot; an empty journal is not a new exception.
        again = self.run_recovery(); self.assertFalse(again['cleared']); self.assertIn('error', again)

    def test_both_exact_rank_cases_and_explicit_identity_refusals(self):
        for rank in (0,1):
            j, raw = evidence(BASE/'evidence',rank,CASES[rank]['peerID'],CASES[rank]['sha256'],CONTROLLER_SHA)
            self.assertEqual(known_journal(rank,raw['rank%d-journal.json'%rank]),j)
        for peer, journal_hash, controller_hash in [('wrong',CASES[0]['sha256'],CONTROLLER_SHA),
                (CASES[0]['peerID'],'0'*64,CONTROLLER_SHA),(CASES[0]['peerID'],CASES[0]['sha256'],'0'*64)]:
            with self.assertRaises(RecoveryRefusal): evidence(BASE/'evidence',0,peer,journal_hash,controller_hash)
        with self.assertRaises(RecoveryRefusal): known_journal(0,self.original.replace(b'"rank":0',b'"rank":1'))

    def test_missing_or_altered_cleanup_evidence_refuses_before_file_operation(self):
        folder = self.base/'evidence';folder.mkdir(mode=0o700)
        with self.assertRaises(OSError): evidence(folder,0,CASES[0]['peerID'],CASES[0]['sha256'],CONTROLLER_SHA)
        for name,raw in self.evidence.items():
            file=folder/name;file.write_bytes(raw);file.chmod(0o600)
        file=folder/'controller.stdout.jsonl'
        file.write_bytes(file.read_bytes().replace(b'[true,true]',b'[false,true]'))
        with self.assertRaises(RecoveryRefusal): evidence(folder,0,CASES[0]['peerID'],CASES[0]['sha256'],CONTROLLER_SHA)
        self.assertEqual(self.file.read_bytes(),self.original)

    def test_changed_record_and_held_lock_refuse_without_backup(self):
        self.file.write_bytes(self.original+b' ')
        result=self.run_recovery();self.assertFalse(result['cleared']);self.assertFalse(result['truncateAttempted'])
        self.file.write_bytes(self.original)
        with self.file.open('r+b') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.unchanged(self.run_recovery())
        self.assertEqual(list(self.directory.iterdir()),[self.file])

    def test_permissions_hardlink_symlink_and_wrong_owner_refuse(self):
        self.file.chmod(0o644); self.unchanged(self.run_recovery());self.file.chmod(0o600)
        other=self.base/'link';os.link(self.file,other);self.unchanged(self.run_recovery());other.unlink()
        self.file.rename(other);self.file.symlink_to(other)
        result=self.run_recovery();self.assertFalse(result['cleared']);self.assertFalse(result['truncateAttempted'])
        self.file.unlink();other.rename(self.file)
        actual=os.geteuid()
        with patch('recovery_files.os.geteuid',return_value=actual+1): self.unchanged(self.run_recovery())

    def test_late_record_or_path_replacement_after_backup_refuses(self):
        def changed(until):
            sample=self.quiet(until)
            if len(self.samples)==2:self.file.write_bytes(self.original+b' ')
            return sample
        result=self.run_recovery(changed)
        self.assertFalse(result['cleared']);self.assertFalse(result['truncateAttempted'])
        self.assertEqual((Path(result['backupDirectory'])/'journal.before.json').read_bytes(),self.original)
        self.file.write_bytes(self.original);self.samples=[]
        def replaced(until):
            sample=self.quiet(until)
            if len(self.samples)==2:
                self.file.rename(self.directory/'old-inode')
                self.file.write_bytes(self.original);self.file.chmod(0o600)
            return sample
        self.unchanged(self.run_recovery(replaced))

    def test_backup_sync_failure_and_tampering_never_clear(self):
        original_sync=os.fsync
        calls=[]
        def sync(fd):
            calls.append(fd)
            if len(calls)==2:raise OSError('fixture backup fsync failure')
            return original_sync(fd)
        with patch('recovery_files.os.fsync',side_effect=sync):self.unchanged(self.run_recovery())
        self.samples=[]
        def tamper(until):
            sample=self.quiet(until)
            if len(self.samples)==2:
                backups=list(self.directory.glob('administrative-recovery-*'))
                for folder in backups:
                    f=folder/'journal.before.json'
                    if f.exists():f.write_bytes(b'changed')
            return sample
        self.unchanged(self.run_recovery(tamper))

    def test_active_process_deadline_and_interruption_refuse(self):
        self.unchanged(self.run_recovery(lambda _:dict(prohibited=[dict(pid=42,executable='cluster-inference')])))
        expired=recover(self.directory,self.journal,self.evidence,time.monotonic()-1,self.quiet)
        self.unchanged(expired)
        def interrupt(_):raise KeyboardInterrupt('fixture interruption')
        self.unchanged(self.run_recovery(interrupt))

    def test_process_parser_covers_actual_owner_reference_families(self):
        raw=b' 0 0 kernel_task\n 12 501 /a/cluster-inference\n 13 501 /a/owner-controller\n 14 501 /a/darkbloom-cluster-worker\n 15 501 /a/qwen-probe\n'
        self.assertEqual([x['pid'] for x in parse_processes(raw)['prohibited']],[12,13,14,15])
        for bad in [b'',b'1 501 /a/cluster-inference',b'bad row\n']:
            with self.assertRaises(RecoveryRefusal):parse_processes(bad)

    def test_actual_kernel_observation_refuses_owned_child(self):
        # Keep the signed system executable intact. Only this test extends the
        # forbidden-name set to the owned sleep fixture; the production names
        # are independently covered by the parser case above.
        child=subprocess.Popen(['/bin/sleep','10'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            with patch('recovery_processes.NATIVE_OR_OWNER_NAMES',NATIVE_OR_OWNER_NAMES|{'sleep'}):
                sample=observe(time.monotonic()+5)
                self.assertIn(child.pid,[x['pid'] for x in sample['prohibited']])
                result=self.run_recovery(observe);self.unchanged(result)
                self.assertEqual(result['observations'][0]['command'],['/bin/ps','-Aww','-o','pid=,uid=,comm='])
        finally:
            child.terminate();child.wait(timeout=3)


if __name__=='__main__':unittest.main()
