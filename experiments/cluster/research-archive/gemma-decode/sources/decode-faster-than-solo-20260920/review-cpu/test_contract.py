"""Small retained-JSON policy controls; no model, native, sidecar or network I/O."""
import copy
import unittest
import dependencies as d

class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = d.c.joined.read(d.OLD / 'harness-v2/cases/p4096-cut7-c64-overlap-v2/pair/stage0/native/worker-0.stdout')
        cls.build = d.c.joined.read(d.BUILD)
        cls.applied = d.c.joined.read(d.APPLIED)
        cls.previous = d.c.joined.read(d.OLD / 'build/applied-control-frame.json')
        cls.integration = d.c.joined.read(d.INTEGRATION)

    def changed(self, mutate):
        value = copy.deepcopy(self.base); mutate(value)
        with self.assertRaises(ValueError): d.contract(value, self.base)

    def test_unchanged_actual_contract_accepts(self): d.contract(copy.deepcopy(self.base), self.base)
    def test_omitted_request_refuses(self): self.changed(lambda x: x['samples'].pop())
    def test_omitted_frame_refuses(self): self.changed(lambda x: x['samples'][1]['frames'].pop())
    def test_changed_OS_cadence_refuses(self): self.changed(lambda x: x['guardMetrics']['records'][4].update(count=0))
    def test_changed_decode_fault_cadence_refuses(self):
        self.changed(lambda x: x['samples'][1]['guardMetrics']['decode']['records'][6].update(count=0))
    def test_changed_commit_refuses(self):
        self.changed(lambda x: x['samples'][1]['frames'][64]['ownerPhases'][-1].update(committedTokens=0))
    def test_reduced_host_reserve_refuses(self): self.changed(lambda x: x['resources'].update(hostEvidenceReserveBytes=0))
    def test_changed_frame_bound_refuses(self):
        self.changed(lambda x: x['resources']['namedAllocationBounds'].__setitem__(-2, 1))
    def test_changed_prompt_refuses(self): self.changed(lambda x: x['job'].update(promptFileSHA256='0' * 64))
    def test_actual_source_union_accepts(self):
        d.source_composition(self.build, self.applied, self.previous, self.integration)
    def test_unreaped_build_refuses(self):
        build = dict(self.build, compilerReaped=False)
        with self.assertRaises(ValueError): d.source_composition(build, self.applied, self.previous, self.integration)
    def test_unrelated_source_change_refuses(self):
        applied = copy.deepcopy(self.applied); applied['files'][0]['sha256'] = '0' * 64
        with self.assertRaises(ValueError): d.source_composition(self.build, applied, self.previous, self.integration)
    def test_duplicate_source_refuses(self):
        applied = copy.deepcopy(self.applied); applied['files'].append(copy.deepcopy(applied['files'][0]))
        with self.assertRaises(ValueError): d.source_composition(self.build, applied, self.previous, self.integration)

if __name__ == '__main__': unittest.main()
