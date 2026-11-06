"""Fabricated value-only evidence. No test claims a native prefix commit."""
import copy
import unittest
import uuid

from accepted_rounds import POLICY, check_rounds
from audit_common import profile, request_context
from audit_scope import AuditScope
from recorded_math import canonical, digest


def fixture(kept=(2,2,1,2)):
    scope=AuditScope('registered_qwen35_9b',32,16,8,4)
    request='abcdef01-1234-4000-8000-000000000001'
    context=request_context(canonical(list(range(32)))+b'\n',request,scope)
    agreement=dict(schema='qwen_stage_generation_agreement_v1',rankCount=2,membershipEpoch=str(uuid.UUID(int=19)),
        requestID=request,requestFingerprint=context['fingerprint'],profileFingerprint=profile(scope)['fingerprint'],
        sourceConfigurationSHA256=scope.model['configuration'],artifactAggregateSHA256=scope.model['artifact'],
        storageCommitmentSHA256='a'*64,planFingerprint=scope.plan['fingerprint'],stageFingerprints=scope.plan['stages'],
        rankBuildSHA256=['b'*64]*2,numericalPolicySHA256='c'*64,mtpEnabled=True,mtpPolicySHA256=POLICY)
    agreement_pin=digest(b'qwen-stage-generation-v1|agreement|'+canonical(agreement))
    selected=list(range(11,19)); rounds=[]; base=32
    for ordinal,count in enumerate(kept):
        proposal=dict(requestID=request.upper(),roundID=str(uuid.UUID(int=ordinal+10)).upper(),
            agreementFingerprint=agreement_pin,committedTargetInputs=base,seedTokenID=selected[base-32],
            previousTokenChainSHA256=digest(str(base).encode()),proposedTokenID=selected[base-31] if count==2 else 999,
            draftDepth=1,accepted=False)
        descriptor=dict(schema='qwen_target_verification_v1',proposal=proposal,firstSequence=base-30,maximumSteps=2)
        pin=digest(b'qwen-stage-generation-v1|target-verification|'+canonical(descriptor))
        sets=[]
        for step in range(count+1):
            final=step==count; retained=count if final else step+1
            sets.append([dict(verificationFingerprint=pin,rank=rank,base=base,stagedInputs=2,
                retainedInputs=retained,committedInputs=base+retained,pendingInputs=0 if final else 2-retained,
                newlyCommittedInputs=0 if final else 1,isFinal=final) for rank in (0,1)])
        rounds.append(dict(proposal=proposal,verificationFingerprint=pin,stagedInputs=2,keptInputs=count,
                           selectedTokens=selected[base-31:base-31+count],receipts=sets));base+=count
    value=dict(schema='qwen_registered_mtp_accepted_depth1_v1',policySHA256=POLICY,target={},rounds=rounds,
               mtpEnabled=True,correctnessOnly=True,encryptedTransportQualified=False,throughputMeasurementValid=False)
    pair=[copy.deepcopy(value),copy.deepcopy(value)];pair[1]['assistantRequestReleased']=True
    return pair,context,selected,agreement


class AcceptedEvidenceTests(unittest.TestCase):
    def test_repeated_match_mismatch_and_final_two_input_prefix(self):
        _, result=check_rounds(*fixture())
        self.assertEqual(result['matchedDraftTokens'],3)
        self.assertEqual(result['reconciledRoundInputs'],7)
        self.assertTrue(result['nativeAcceptedDraftPathExercised'])

    def test_no_match_remains_explicitly_unexercised(self):
        _, result=check_rounds(*fixture((1,)*6))
        self.assertFalse(result['nativeAcceptedDraftPathExercised'])
        self.assertEqual(result['ordinaryFinalTailInputs'],1)

    def reject(self, mutate, message=None):
        pair,context,tokens,agreement=fixture();mutate(pair,agreement)
        if message is None:
            with self.assertRaises(ValueError):check_rounds(pair,context,tokens,agreement)
        else:
            with self.assertRaisesRegex(ValueError,message):check_rounds(pair,context,tokens,agreement)

    def test_policy_substitution(self):
        self.reject(lambda p,a:a.update(mtpPolicySHA256='0'*64),'closed accepted policy')

    def test_disabled_agreement(self):
        self.reject(lambda p,a:a.update(mtpEnabled=False),'accepted agreement enabled')

    def test_reused_round_uuid(self):
        def change(p,a):
            for x in p:x['rounds'][1]['proposal']['roundID']=x['rounds'][0]['proposal']['roundID']
        self.reject(change,'Repeated proposal UUID')

    def test_wrong_seed(self):
        def change(p,a):
            for x in p:x['rounds'][0]['proposal']['seedTokenID']=12
        self.reject(change,'actual target-selected seed')

    def test_frontier_skip(self):
        def change(p,a):
            for x in p:x['rounds'][1]['proposal']['committedTargetInputs']+=1
        self.reject(change,'proposal committed base')

    def test_duplicate_receipt_rank(self):
        def change(p,a):
            for x in p:x['rounds'][0]['receipts'][0][1]['rank']=0
        self.reject(change,'accepted rank receipt.rank')

    def test_commit_pending_suffix_must_match(self):
        def change(p,a):
            for x in p:x['rounds'][0]['receipts'][0][0]['pendingInputs']=0
        self.reject(change,'accepted rank receipt.pendingInputs')

    def test_final_receipt_cannot_add_unpublished_input(self):
        def change(p,a):
            for x in p:x['rounds'][0]['receipts'][-1][1]['newlyCommittedInputs']=1
        self.reject(change,'accepted rank receipt.newlyCommittedInputs')

    def test_kept_two_requires_actual_target_match(self):
        def change(p,a):
            for x in p:x['rounds'][0]['proposal']['proposedTokenID']=999
        self.reject(change,'target match determines retained prefix')

    def test_missing_later_round(self):
        def change(p,a):
            for x in p:x['rounds']=x['rounds'][:1]
        self.reject(change,'Every available multi-input round')

    def test_both_rank_rounds_must_match(self):
        self.reject(lambda p,a:p[1]['rounds'].pop(),'Both rank round transcripts')

    def test_assistant_must_report_actual_release(self):
        self.reject(lambda p,a:p[1].update(assistantRequestReleased=False),'assistant request release')


if __name__=='__main__':unittest.main()
