"""Targeted CPU-only replacement and mismatch controls; no subprocess/network."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
BASE=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(BASE/'proposed'),str(BASE),str(BASE/'package'),str(BASE.parent/'gemma4-short-physical-draft-20260916/package')]
from terminal_binding import describe_launch,recheck_launch,require_terminal


class Checks(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve();self.path=self.root/'launch.json'
    def tearDown(self):self.temp.cleanup()
    def write(self,modes):
        value=dict(status='completed',exitCodes=[0]*len(modes),cleanupErrors=[],reaped=True,outputComplete=True,watchdogExpired=False,
                   results=[dict(mode=m,status='completed',terminalSHA256=str(i+1)*64) for i,m in enumerate(modes)])
        self.path.write_text(json.dumps(value));return value
    def test_full_exact_join(self):
        self.write(['full']);ref=describe_launch(self.path,'full');recheck_launch(ref,'full');require_terminal(ref,'full','1'*64)
    def test_pair_exact_join(self):
        self.write(['stage0','stage1']);ref=describe_launch(self.path,'stages');recheck_launch(ref,'stages')
        require_terminal(ref,'stage0','1'*64);require_terminal(ref,'stage1','2'*64)
    def test_collected_replacement_refused(self):
        self.write(['full']);ref=describe_launch(self.path,'full')
        with self.assertRaises(ValueError):require_terminal(ref,'full','3'*64)
        self.write(['stage0','stage1']);ref=describe_launch(self.path,'stages')
        with self.assertRaises(ValueError):require_terminal(ref,'stage0','2'*64)
        with self.assertRaises(ValueError):require_terminal(ref,'stage1','1'*64)
    def test_original_launch_replacement_refused(self):
        value=self.write(['full']);ref=describe_launch(self.path,'full');value['results'][0]['terminalSHA256']='3'*64;self.path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):recheck_launch(ref,'full')
    def test_missing_duplicate_and_swapped_roles_refused(self):
        for modes in (['stage0'],['stage0','stage0'],['stage1','stage0']):
            self.write(modes)
            with self.assertRaises(ValueError):describe_launch(self.path,'stages')
    def test_incomplete_launch_refused(self):
        for key,value in [('outputComplete',False),('reaped',False),('watchdogExpired',True),('exitCodes',[1])]:
            row=self.write(['full']);row[key]=value;self.path.write_text(json.dumps(row))
            with self.assertRaises(ValueError):describe_launch(self.path,'full')
if __name__=='__main__':unittest.main()
