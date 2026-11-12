import copy
import unittest

from fabricated_rank import ready
from selected_read_accounting import ALIGNMENT, SCRATCH, FIELD, validated_load
import test_physical as physical


class SelectedReads(unittest.TestCase):
    setUp=physical.Contracts.setUp
    validator=physical.Contracts.validator

    def test_aligned_policy_and_counters(self):
        v=self.validator()
        for rank in (0,1):
            actual=ready(v,rank,100+rank)['execution']['sourceLoad']
            self.assertEqual(validated_load(actual,v.loads[rank]),actual)
            interrupted=copy.deepcopy(actual);a=interrupted[FIELD]
            a['interruptedCalls']+=1;a['preadCalls']+=1;a['requestedReadBytes']+=SCRATCH
            self.assertEqual(validated_load(interrupted,v.loads[rank]),interrupted)
            eof=copy.deepcopy(actual);a=eof[FIELD]
            a['shortEOFReads']=1;a['returnedReadBytes']-=1;a['paddingReadBytes']-=1
            self.assertEqual(validated_load(eof,v.loads[rank]),eof)

    def test_malformed_or_changed_receipts_rejected(self):
        v=self.validator();base=ready(v,0,100)['execution']['sourceLoad']
        changes=[lambda x:x.pop(FIELD),lambda x:x.update(loadedTensorBytes=1),
            lambda x:x[FIELD].update(extra=True),lambda x:x[FIELD].update(cacheBypassRequested=1),
            lambda x:x[FIELD].update(fileCacheAbsenceEstablished=True),
            lambda x:x[FIELD].update(alignmentBytes=4096),lambda x:x[FIELD].update(selectedBytes=True),
            lambda x:x[FIELD].update(selectedBytes=x['loadedTensorBytes']+1),
            lambda x:x[FIELD].update(returnedReadBytes=0),lambda x:x[FIELD].update(preadCalls=0),
            lambda x:x[FIELD].update(interruptedCalls=2**63),
            lambda x:x[FIELD].update(requestedReadBytes=x[FIELD]['requestedReadBytes']+1),
            lambda x:x[FIELD].update(shortEOFReads=10000),
            lambda x:x[FIELD].update(shortEOFReads=1),
            lambda x:x[FIELD].update(largestScratchAllocationBytes=SCRATCH+ALIGNMENT+1),
            lambda x:x[FIELD].update(largestScratchRequestBytes=SCRATCH-ALIGNMENT)]
        for change in changes:
            actual=copy.deepcopy(base);change(actual)
            with self.subTest(change=change),self.assertRaises(ValueError):
                validated_load(actual,v.loads[0])


if __name__=='__main__':unittest.main()
