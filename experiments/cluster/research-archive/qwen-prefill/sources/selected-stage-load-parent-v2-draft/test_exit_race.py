"""Invented exit-during-observation cases; no process, native or candidate IO."""
from pathlib import Path
import socket
import tempfile
import types
import unittest
from unittest.mock import patch

import run_selected_stage_load as parent
import stage_load_contract as contract
import test_selected_stage_parent as old


class ExitingProcess:
    pid = 91234
    def __init__(self, events, code=0, confirms=True):
        self.events=events;self.code=code;self.confirms=confirms;self.sampled=False;self.returncode=None
    def poll(self):
        self.events.append('poll')
        if self.sampled and self.confirms:self.returncode=self.code
        return self.returncode
    def wait(self, timeout=None):
        self.events.append('wait')
        if self.returncode is None:raise AssertionError('Fixture child has not exited')
        return self.returncode


class ExitRaceTests(unittest.TestCase):
    def setUp(self):
        self.guards=[patch('subprocess.Popen',side_effect=AssertionError('real process forbidden')),
                     patch('subprocess.run',side_effect=AssertionError('real subprocess forbidden')),
                     patch.object(socket,'socket',side_effect=AssertionError('network forbidden'))]
        for item in self.guards:item.start()
    def tearDown(self):
        for item in reversed(self.guards):item.stop()
    def setup_case(self, code=0, confirms=True, changes=None, power=old.BATTERY):
        events=[];process=ExitingProcess(events,code,confirms)
        observation=dict(old.sample(process.pid,Path('/unused')),nativeRSSBytes=0,nativeCommand='<defunct>')
        observation.update(changes or {})
        def sample(pid):
            self.assertEqual(pid,process.pid);events.append('sample');process.sampled=True
            return dict(observation)
        def read_command(args):
            self.assertEqual(args,['/usr/bin/pmset','-g','batt']);events.append('power');return power
        tiny=types.SimpleNamespace(sample=sample,read_command=read_command)
        receipt=dict(memorySamples=[],powerObservations=[],registeredProfile=old.PROFILE,stageIndex=0)
        return process,tiny,receipt,events
    def observe(self, case):
        process,tiny,receipt,_=case
        return parent.observe(tiny,receipt,contract.PROFILES[old.PROFILE],process,Path('/fake/bundle/cluster-inference'))
    def test_exact_terminal_zero_rss_is_classified_after_actual_poll(self):
        case=self.setup_case();sample=self.observe(case)
        self.assertEqual(case[3],['sample','poll','power'])
        self.assertEqual(sample['nativeCommand'],'<defunct>');self.assertEqual(sample['nativeRSSBytes'],0)
        self.assertEqual(sample['nativePID'],case[0].pid);self.assertEqual(sample['nativePGID'],case[0].pid)
        self.assertEqual(sample['terminalExitCodeObservedAfterSample'],0)
        self.assertEqual(sample['nativeObservationClassification'],'owned_terminal_during_observation')
        self.assertFalse(sample['defunctSampleIsLiveRSS'])
    def test_defunct_but_poll_still_running_refuses(self):
        case=self.setup_case(confirms=False)
        with self.assertRaises(ValueError):self.observe(case)
        self.assertIsNone(case[0].returncode)
        self.assertIsNone(case[2]['memorySamples'][0]['terminalExitCodeObservedAfterSample'])
        self.assertNotIn('nativeObservationClassification',case[2]['memorySamples'][0])
    def test_wrong_pid_or_group_never_qualifies(self):
        for changes in [dict(nativePID=91235),dict(nativePGID=91235),dict(nativePID=True),dict(nativePGID=True)]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):self.observe(self.setup_case(changes=changes))
    def test_defunct_requires_exact_integer_zero_rss(self):
        for rss in (1,-1,None,True,0.0):
            with self.subTest(rss=rss),self.assertRaises(ValueError):self.observe(self.setup_case(changes=dict(nativeRSSBytes=rss)))
    def test_terminal_confirmation_is_exact_integer(self):
        for code in (True,0.0,'0'):
            with self.subTest(code=code),self.assertRaises(ValueError):self.observe(self.setup_case(code=code))
    def test_near_markers_or_other_commands_stay_rejected(self):
        for command in (' <defunct>','<defunct> extra','(defunct)','/fake/cluster-inference <defunct>','other'):
            case=self.setup_case(changes=dict(nativeCommand=command))
            with self.subTest(command=command),self.assertRaises(ValueError):self.observe(case)
            self.assertNotIn('terminalExitCodeObservedAfterSample',case[2]['memorySamples'][0])
    def test_exit_race_still_checks_each_resource_and_power_limit(self):
        for changes in [dict(actualFreeBytes=contract.MINIMUM_FREE-1),dict(pressureLevel=3),dict(reportedSwapBytes='1')]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):self.observe(self.setup_case(changes=changes))
        with self.assertRaises(ValueError):self.observe(self.setup_case(power=old.BATTERY.replace('19%','14%')))
    def run_supervisor(self, code=0, clock=lambda:0):
        case=self.setup_case(code=code);process,tiny,receipt,_=case
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory);(out/'stdout.jsonl').write_bytes(old.raw(old.result()));(out/'stderr.log').write_bytes(b'')
            parent.supervise(process,out,tiny,receipt,contract.PROFILES[old.PROFILE],lambda:None,clock=clock,deadline=135)
        return receipt
    def test_successful_exit_race_finishes_outer_validation_and_reap(self):
        receipt=self.run_supervisor()
        self.assertTrue(receipt['nativeReaped']);self.assertEqual(receipt['nativeExitCode'],0)
        self.assertTrue(receipt['outerIdentityAndScopeValidated'])
    def test_nonzero_exit_is_still_native_failure(self):
        with self.assertRaisesRegex(ValueError,'Native selected-stage load failed'):self.run_supervisor(code=1)
    def test_exit_race_does_not_bypass_observation_deadline(self):
        with self.assertRaisesRegex(ValueError,'deadline exceeded after observation'):self.run_supervisor(clock=lambda:135)


if __name__=='__main__':unittest.main()
