"""Frozen member + native approval overlays and bounded Go inputs; no import IO."""
from pathlib import Path
BASE = Path(__file__).resolve().parent.parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference')
GO = '/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go'
GO_SHA = 'c812de5f1e8307431c5bce8ebc4887c180827abc5834a72cd640a8a14200a93b'
GO_PACKAGES = ('coordinator/registry', 'coordinator/protocol', 'coordinator/api')
GO_FILTER = '^Test(NativePair|VerifiedPair|ClusterMember|MemberRole)'
NATIVE_PAIR_METHODS = frozenset((
    'TestNativePairMeshActualReadLoopRefusesWithoutGrant',
    'TestNativePairMeshFourRoundsPreserveOrderAndGrant',
    'TestNativePairMeshRefusesEarlyWrongContextAndSequence',
    'TestNativePairMeshWrongKeyConfirmationNeverStartsMesh',
    'TestNativePairMeshIndependentPublicVector',
    'TestNativePairMeshClosedSizesAndDirections',
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
