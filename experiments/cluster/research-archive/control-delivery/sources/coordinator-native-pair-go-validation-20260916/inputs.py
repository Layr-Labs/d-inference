"""Frozen member + native approval overlays and bounded Go inputs; no import IO."""
from pathlib import Path
BASE = Path(__file__).resolve().parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference')
OVERLAY = BASE.parent / 'cluster-registered-member-draft-20260915'
OVERLAY_SHA = '4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965'
GO = '/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go'
GO_SHA = 'c812de5f1e8307431c5bce8ebc4887c180827abc5834a72cd640a8a14200a93b'
GO_PACKAGES = ('coordinator/registry', 'coordinator/protocol', 'coordinator/api')
GO_FILTER = '^Test(NativePair|VerifiedPair|ClusterMember|MemberRole)'
B_OVERLAY = BASE.parent / 'coordinator-native-pair-authorization-draft-20260916'
B_OVERLAY_SHA = '69189730ac9df0ced27006c2b00606583a20f905a7140cfc8fff5f24ff9dc500'
CORRECTION = BASE.parent / 'coordinator-native-pair-cancel-order-correction-20260916'
CORRECTION_SHA = '4339ee6034187060459c11b4879f722318aee2578f2d44bbf6936e3715e80745'
UPSTREAM = BASE.parent / 'cluster-registered-member-validation-fixtures-20260916'
UPSTREAM_SHA = '0550d8fb270ac4dbef474fc0585497d7bf8c612ca35812cca6f76ac6ade2be06'
NATIVE_PAIR_METHODS = frozenset((
    'TestNativePairNoSelfApprovalAndNoSoloAttachment',
    'TestNativePairCommitPrecedesStartAndBindingUsesExactHello',
    'TestNativePairCancellationRetainsUntilActualOriginalRelease',
    'TestNativePairFalseCleanupAndReplayNeverRelease',
    'TestNativePairPreparedCannotLaunchHelloBeforeCommit',
    'TestNativePairRevocationCannotRestoreOriginalGrant',
    'TestNativePairReconnectCannotReleaseOldActiveOwner',
    'TestNativePairBoundedRelayAndCancellation',
    'TestNativePairRevokeRacingSecondPreparationNeverLeavesActive',
    'TestNativePairWrongConnectionNonceAndSignatureRefused',
    'TestNativePairFixedLifetimeExpiresWithoutOwnerRelease',
    'TestNativePairPendingCancelPublicationPrecedesConnectionReuse',
    'TestNativePairPublicBytesMatchQualifiedSwiftPrelude',
    'TestNativePairClosedPublicEnvelope',
    'TestNativePairAPIDefaultDisabledAndUnregisteredFrameRefused',
    'TestNativePairActualTLSStateNotForwardedHeader',
))
