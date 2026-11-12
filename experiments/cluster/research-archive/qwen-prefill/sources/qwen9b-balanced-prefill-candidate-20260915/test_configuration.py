import base64
import copy
import hashlib
import json
from pathlib import Path
import unittest
import uuid
from prepare_configuration import BASE, CASES, REMOTE, NATIVE_SHA, PROMPT_SHA, case_configuration, record

class ConfigurationTests(unittest.TestCase):
    def test_all_outer_and_ready_records_are_one_bounded_line(self):
        for name in CASES:
            expected = case_configuration(name)
            for filename, value in zip(['controller', 'owner-rank0', 'owner-rank1', 'matrix'],
                    [expected[0], *expected[1], expected[2]]):
                raw = (BASE / 'cases' / name / 'configuration' / (filename + '.json')).read_bytes()
                self.assertEqual(raw, record(value))
                self.assertEqual(raw.count(b'\n'), 1)
                self.assertTrue(raw.endswith(b'\n'))
                self.assertLessEqual(len(raw), 16_384 if filename.startswith('owner') else 256*1024)
                if 'readyTemplateBase64' in value:
                    template = base64.b64decode(value['readyTemplateBase64'], validate=True)
                    self.assertEqual(template.count(b'\n'), 1)
                    self.assertLess(len(template), 16_384)
                    self.assertEqual(record(json.loads(template)), template)

    def test_matched_geometry_and_fresh_epochs(self):
        epochs = set()
        prompt = (BASE / 'inputs/prompt.ids.json').read_bytes()
        self.assertEqual(hashlib.sha256(prompt).hexdigest(), PROMPT_SHA)
        for name in CASES:
            c, owners, _, _ = case_configuration(name)
            self.assertEqual(c['promptTokenIDs'], json.loads(prompt))
            self.assertEqual((len(c['promptTokenIDs']), c['chunkSize'], c['outputCount'], c['stopTokenIDs']), (8192,512,128,[]))
            self.assertEqual(str(uuid.UUID(c['membershipEpoch'])), c['membershipEpoch'])
            self.assertNotIn(c['membershipEpoch'], epochs); epochs.add(c['membershipEpoch'])
            self.assertFalse(c['cpuQualification'])
            self.assertEqual(c['lifetimeSeconds'], 300)
            if name.endswith('-timing'):
                self.assertEqual((c['warmupCount'],c['measuredCount']), (1,3))
                self.assertEqual(len(c['expectedTokenIDs']),128)
            else:
                self.assertIsNone(c['expectedTokenIDs'])

    def test_templates_do_not_claim_capacity_and_require_actual_native(self):
        for name, (cut, _) in CASES.items():
            c, owners, matrix, agreement = case_configuration(name)
            metadata = json.loads((BASE/f'metadata/cut{cut}.json').read_bytes())
            self.assertEqual(matrix, [[None,'rdma_en1'],['rdma_en1',None]])
            for rank, o in enumerate(owners):
                ready = json.loads(base64.b64decode(o['readyTemplateBase64']))['ready']
                self.assertEqual(ready['rank'],rank)
                self.assertEqual(ready['requestCapacityBytes'],1)
                self.assertEqual(ready['executionPlanSHA256'],metadata['planFingerprint'])
                self.assertEqual([p['buildSHA256'] for p in ready['identity']['peers']],[NATIVE_SHA]*2)
                self.assertEqual(o['stageCut'],cut)
                self.assertEqual(o['leaseDirectory'],'/Users/developer/.darkbloom/cluster-device')
                self.assertEqual(o['workerExecutable'],REMOTE+'/native/darkbloom-cluster-worker')
                self.assertEqual(o['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'],'one_chunk_lookahead_v1')
                self.assertEqual(o['workerEnvironment']['JACCL_RANK'],str(rank))
                self.assertEqual(o['workerEnvironment']['JACCL_IBV_DEVICES'],REMOTE+'/'+name+'/matrix.json')
                self.assertEqual(c['peers'][rank]['installedOwner'],REMOTE+'/'+name+'/darkbloom-owner-qualification')
            self.assertFalse(agreement['mtpEnabled'])
            self.assertEqual(agreement['prefillSchedulingPolicy'],'oneChunkLookahead')
            self.assertEqual(agreement['storageCommitmentSHA256'],metadata['loads'][0]['storageCommitmentSHA256'])

    def test_both_cuts_conserve_source_and_full_state(self):
        unions=[]
        for cut, counts in [(4,[9,63]),(16,[36,36])]:
            m=json.loads((BASE/f'metadata/cut{cut}.json').read_bytes())
            names=[x['sourceName'] for r in m['loads'] for x in r['activeTensors']]
            self.assertEqual((len(names),len(set(names))), (927,927))
            self.assertEqual(sum(x['byteCount'] for r in m['loads'] for x in r['activeTensors']),5038041600)
            states=[[(s['layer']['globalIndex'],c) for s in rank for c in s['components']] for rank in m['states']]
            self.assertEqual(list(map(len,states)),counts)
            self.assertEqual(len(set(states[0]+states[1])),72)
            unions.append(states[0]+states[1])
        self.assertEqual(*unions)

    def test_parent_adapter_preserves_cleanup_and_selects_exact_local_controller(self):
        from run_case import configure_parent
        for name in CASES:
            p=configure_parent(name)
            self.assertEqual(p.BASE,BASE/'cases'/name)
            self.assertEqual(p.OUTPUT,p.BASE/'physical-1')
            self.assertEqual(p.REMOTE,REMOTE+'/'+name)
            self.assertEqual(p.CONTROLLER.name,'owner-timing-controller' if name.endswith('-timing') else 'owner-controller')
        with self.assertRaises(ValueError): configure_parent('../escape')
        with self.assertRaises(ValueError): case_configuration('cut8-correctness')

    def test_nonfinite_configuration_is_refused(self):
        with self.assertRaises(ValueError): record({'timeout':float('nan')})

if __name__=='__main__':unittest.main()
