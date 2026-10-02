"""Prospective small-file controls; no actual model, SSH, or canonical lease."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import artifact
import remote_control
import rsync_exec
from lease_gate import acquire

class TransferTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir='/private/tmp');self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def test_hash_and_replacement(self):
        p=self.root/'small';p.write_bytes(b'registered bytes');p.chmod(0o600)
        row=artifact.hash_file(p,16,hashlib.sha256(b'registered bytes').hexdigest(),time.monotonic()+2)
        with self.assertRaises(ValueError):artifact.hash_file(p,16,'0'*64,time.monotonic()+2)
        p.unlink();p.write_bytes(b'registered bytes');p.chmod(0o600)
        with self.assertRaises(ValueError):artifact.recheck(self.root,dict(files=[],manifest=row))
    def test_symlink_hardlink_and_deadline(self):
        p=self.root/'small';p.write_bytes(b'x');p.chmod(0o600)
        link=self.root/'link';link.symlink_to(p)
        with self.assertRaises(ValueError):artifact.inspect(link)
        link.unlink();os.link(p,link)
        with self.assertRaises(ValueError):artifact.inspect(p)
        link.unlink()
        with self.assertRaises(ValueError):artifact.hash_file(p,1,hashlib.sha256(b'x').hexdigest(),time.monotonic()-1)
    def test_gate_held_and_marker_refusal(self):
        p=self.root/'native-device.lease';p.write_bytes(b'');p.chmod(0o600)
        fd,gate=acquire(self.root)
        try:
            with self.assertRaises(BlockingIOError):acquire(self.root)
            self.assertEqual(p.stat().st_ino,gate['fileInode'])
        finally:os.close(fd)
        p.write_bytes(b'sticky')
        with self.assertRaises(ValueError):acquire(self.root)
        self.assertEqual(p.read_bytes(),b'sticky')
    def test_atomic_no_overwrite(self):
        source=self.root/'source';source.mkdir();(source/'file').write_bytes(b'exact')
        destination=self.root/'destination';destination.mkdir();(destination/'sentinel').write_bytes(b'keep')
        with self.assertRaises(OSError):remote_control.promote(source,destination)
        self.assertEqual((destination/'sentinel').read_bytes(),b'keep')
        self.assertEqual((source/'file').read_bytes(),b'exact')
        final=self.root/'final';remote_control.promote(source,final)
        self.assertFalse(source.exists());self.assertEqual((final/'file').read_bytes(),b'exact')
    def test_receiver_role_path_rejected_before_gate(self):
        base=rsync_exec.BASE
        for args in (['--sender','-rt','.','/wrong'],['--server','-rt','.','/wrong'],['--server','--delete','.','/wrong']):
            with patch.object(rsync_exec,'PREPARATION',base),patch.object(rsync_exec,'check_sources',return_value='pin'),patch.object(sys,'argv',['receiver']+args),patch.object(rsync_exec,'acquire') as gate:
                with self.assertRaises(ValueError):rsync_exec.main()
                gate.assert_not_called()
    def test_receiver_retains_gate_through_same_group_wait(self):
        base=rsync_exec.BASE;p=self.root/'lease';p.write_bytes(b'');fd=os.open(p,os.O_RDONLY)
        class Child:
            returncode=None
            def wait(inner,timeout):
                self.assertEqual(os.fstat(fd).st_ino,p.stat().st_ino);self.assertEqual(timeout,880);inner.returncode=0;return 0
        with patch.object(rsync_exec,'PREPARATION',base),patch.object(rsync_exec,'check_sources',return_value='pin'),patch.object(sys,'argv',['receiver','--server','-rt','.',str(rsync_exec.STAGE)]),patch.object(rsync_exec,'acquire',return_value=(fd,{})),patch.object(rsync_exec,'observe',return_value={'prohibited':[]}),patch.object(rsync_exec,'disk',return_value={}),patch.object(rsync_exec,'record'),patch.object(rsync_exec.subprocess,'Popen',return_value=Child()) as child:
            rsync_exec.main();self.assertEqual(child.call_args.kwargs,{})
        with self.assertRaises(OSError):os.fstat(fd)
if __name__=='__main__':unittest.main()
