"""Small negative controls only; no native execution or sidecar reads."""
import copy
import unittest
import compare_three_roles as c


class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=c.joined.read(c.BASE/'cases/p4096-cut7-c64-overlap-v7/pair/stage0/native/worker-0.stdout')

    def candidate(self):
        return copy.deepcopy(self.base)

    def test_unchanged_contract_accepts(self):
        value=self.candidate();c.same_cadence(value,self.base);c.same_budget(value,self.base);c.matched_workload(value,self.base)

    def test_global_os_read_change_refuses(self):
        value=self.candidate();value['guardMetrics']['records'][4]['count']-=1
        with self.assertRaises(ValueError):c.same_cadence(value,self.base)

    def test_prefill_call_change_refuses(self):
        value=self.candidate();value['samples'][1]['guardMetrics']['prefill']['records'][0]['count']-=1
        with self.assertRaises(ValueError):c.same_cadence(value,self.base)

    def test_decode_native_fault_change_refuses(self):
        value=self.candidate();value['samples'][3]['guardMetrics']['decode']['records'][6]['count']-=1
        with self.assertRaises(ValueError):c.same_cadence(value,self.base)

    def test_owner_frontier_change_refuses(self):
        value=self.candidate();value['samples'][1]['frames'][64]['ownerPhases'][-1]['committedTokens']-=1
        with self.assertRaises(ValueError):c.same_cadence(value,self.base)

    def test_reserve_reduction_refuses(self):
        value=self.candidate();value['resources']['hostEvidenceReserveBytes']-=1
        with self.assertRaises(ValueError):c.same_budget(value,self.base)

    def test_same_sum_relabelled_reserve_refuses(self):
        value=self.candidate();value['resources']['namedArrays'][0]['name']+='-other'
        with self.assertRaises(ValueError):c.same_budget(value,self.base)

    def test_prompt_change_refuses(self):
        value=self.candidate();value['job']['promptFileSHA256']='1'*64
        with self.assertRaises(ValueError):c.matched_workload(value,self.base)

    def test_explicit_identity_only_changes_accept(self):
        value=self.candidate();value['job']['membershipEpoch']='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        value['job']['buildIdentitySHA256']=c.NEW_NATIVE
        value['job']['requestIDs']=['different-identity']*4
        # Only this pure semantic matching routine permits different identities;
        # prospective job pins and actual launch/runtime helpers validate them.
        c.matched_workload(value,self.base)

    def test_boolean_guard_count_refuses(self):
        value=self.candidate();value['guardMetrics']['records'][0]['count']=True
        with self.assertRaises(ValueError):c.same_cadence(value,self.base)


if __name__=='__main__':unittest.main()
