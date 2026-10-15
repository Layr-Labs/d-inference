"""Closed P32/C16/O8 depth-one evidence, separate from the ordinary validator."""
from audit_common import (AGREEMENT_KEYS, agreement as ordinary_agreement, canonical_uuid,
                          exact, fields, integer, sha)
from audit_scope import scope_for
from recorded_math import canonical, digest, require

POLICY = digest(b'registered-qwen35-9b-mtp-depth1-short-v1|cut4|serial|P1-32|C1-16|O2-8|emptyStops|target-prefix-receipts|assistant-finalize|plain-lab')


def accepted_agreement(value, context):
    scope = scope_for(context)
    require((scope.model_id, scope.cut, scope.prompt, scope.chunk, scope.output) ==
            ('registered_qwen35_9b', 4, 32, 16, 8), 'Closed accepted comparison shape')
    fields(value, AGREEMENT_KEYS + ' mtpPolicySHA256', 'accepted agreement')
    exact(value['mtpEnabled'], True, 'accepted agreement enabled')
    exact(value['mtpPolicySHA256'], POLICY, 'closed accepted policy')
    # Reuse only the ordinary identity/geometry validator. This projected local
    # value is never used as evidence or passed to the ordinary target comparator.
    identity = {k:v for k,v in value.items() if k != 'mtpPolicySHA256'}
    identity['mtpEnabled'] = False
    ordinary_agreement(identity, context)
    return digest(b'qwen-stage-generation-v1|agreement|' + canonical(value))


def check_receipts(values, fingerprint, base, kept):
    require(type(values) is list and len(values) == kept + 1, 'Every commit and final receipt set required')
    for index, pair in enumerate(values):
        final = index == kept
        retained = kept if final else index + 1
        require(type(pair) is list and len(pair) == 2, 'Exactly two actual rank receipts required')
        for rank, actual in enumerate(pair):
            expected = dict(verificationFingerprint=fingerprint, rank=rank, base=base,
                stagedInputs=2, retainedInputs=retained, committedInputs=base + retained,
                pendingInputs=0 if final else 2-retained,
                newlyCommittedInputs=0 if final else 1, isFinal=final)
            exact(actual, expected, 'accepted rank receipt')


def check_rounds(evidence, context, selected, expected_agreement):
    agreement_pin = accepted_agreement(expected_agreement, context)
    require(type(evidence) is list and len(evidence) == 2, 'Both accepted envelopes required')
    targets = []
    for rank, value in enumerate(evidence):
        names = ('schema policySHA256 target rounds mtpEnabled correctnessOnly '
                 'encryptedTransportQualified throughputMeasurementValid')
        fields(value, names + (' assistantRequestReleased' if rank == 1 else ''), 'accepted envelope')
        for key, wanted in dict(schema='qwen_registered_mtp_accepted_depth1_v1', policySHA256=POLICY,
            mtpEnabled=True, correctnessOnly=True, encryptedTransportQualified=False,
            throughputMeasurementValid=False).items():
            exact(value[key], wanted, 'accepted envelope.' + key)
        if rank == 1:
            exact(value['assistantRequestReleased'], True, 'assistant request release')
        targets.append(value['target'])
    exact(evidence[0]['rounds'], evidence[1]['rounds'], 'Both rank round transcripts')
    rounds = evidence[0]['rounds']
    require(type(rounds) is list and 1 <= len(rounds) <= 7, 'Bounded nonempty accepted rounds')
    base = 32; used = set(); previous_chains = set(); accepted = 0
    for value in rounds:
        require(base <= 37, 'No round may replace the single-input ordinary tail')
        fields(value, 'proposal verificationFingerprint stagedInputs keptInputs selectedTokens receipts', 'accepted round')
        p = fields(value['proposal'], 'requestID roundID agreementFingerprint committedTargetInputs seedTokenID '
                   'previousTokenChainSHA256 proposedTokenID draftDepth accepted', 'proposal')
        # Swift Foundation encodes UUID values uppercase while request identity
        # strings in agreement fingerprints are canonical lowercase.
        exact(p['requestID'], context['request_id'].upper(), 'proposal request')
        canonical_uuid(p['roundID'].lower()); exact(p['roundID'], p['roundID'].upper(), 'proposal UUID encoding')
        require(p['roundID'] not in used, 'Repeated proposal UUID'); used.add(p['roundID'])
        exact(p['agreementFingerprint'], agreement_pin, 'proposal agreement')
        exact(p['committedTargetInputs'], base, 'proposal committed base')
        exact(p['seedTokenID'], selected[base-32], 'proposal actual target-selected seed')
        exact(p['draftDepth'], 1, 'depth one'); exact(p['accepted'], False, 'proposal itself is not acceptance')
        integer(p['proposedTokenID'], 0, 248319)
        chain = sha(p['previousTokenChainSHA256'])
        require(chain not in previous_chains, 'Repeated history chain at a later frontier'); previous_chains.add(chain)
        exact(value['stagedInputs'], 2, 'Two provisional inputs')
        kept = integer(value['keptInputs'], 1, 2)
        tokens = selected[base-31:base-31+kept]
        require(len(tokens) == kept, 'Round exceeds selected output')
        exact(value['selectedTokens'], tokens, 'Target-selected outputs after commit')
        exact(kept, 2 if tokens[0] == p['proposedTokenID'] else 1, 'Length-ended exact target match determines retained prefix')
        descriptor = dict(schema='qwen_target_verification_v1', proposal=p,
                          firstSequence=base-30, maximumSteps=2)
        fingerprint = digest(b'qwen-stage-generation-v1|target-verification|' + canonical(descriptor))
        exact(value['verificationFingerprint'], fingerprint, 'Verification descriptor fingerprint')
        check_receipts(value['receipts'], fingerprint, base, kept)
        accepted += kept-1; base += kept
    require(base in (38, 39), 'Every available multi-input round must be represented')
    return targets, dict(roundCount=len(rounds), matchedDraftTokens=accepted,
        nativeAcceptedDraftPathExercised=accepted > 0,
        reconciledRoundInputs=base-32, ordinaryFinalTailInputs=39-base,
        bilateralReceiptSets=sum(len(x['receipts']) for x in rounds),
        assistantRequestReportedReleased=True, intermediateTokenChainsIndependentlyReconstructed=False,
        actualAssistantHiddenValuesCompared=False)
