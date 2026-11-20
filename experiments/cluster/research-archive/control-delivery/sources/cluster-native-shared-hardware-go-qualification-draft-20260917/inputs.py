from pathlib import Path
BASE=Path(__file__).resolve().parent
ANCESTOR=Path('/Users/developer/DarkbloomDev/cluster-research/cluster-native-shared-request-go-coverage-checks-1-20260917')
WORKSPACE=ANCESTOR/'workspace'
DRIVER=Path('/Users/developer/DarkbloomDev/cluster-research/cluster-native-shared-hardware-driver-draft-20260917')
DRIVER_SHA='e0d428fb6c7b7ea93d67ff6d31aad8f8ca7e47aec9d8f4918f1c0d64340cf80f'
GO='/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go'
GO_SHA='c812de5f1e8307431c5bce8ebc4887c180827abc5834a72cd640a8a14200a93b'
GO_PACKAGES=('coordinator/registry','coordinator/protocol','coordinator/api')
GO_FILTER='^Test(NativePair|VerifiedPair|ClusterMember|MemberRole)'
TAG='native_pair_hardware_experiment'
NATIVE_PAIR_METHODS = frozenset((
    'TestNativePairWorkerExactlyOneReadyNeverAdmitsCommand',
    'TestNativePairWorkerLateFramesCannotEscapeStopOrOneRelease',
    'TestNativePairWorkerAggregatePublicationMustPrecedeReplacement',
    'TestNativePairWorkerAggregateEnqueueFailureClosesOriginalConnection',
    'TestNativePairWorkerRecordAndByteBudgetsUseActualFrames',
    'TestNativePairWorkerPacketClosedFramingAndSlackBounds',
    'TestNativePairWorkerActualReadLoopRefusesAllFourKindsWithoutGrant',
    'TestNativePairWorkerRelayRequiresBothReadyAndPreservesOriginalScope',
    'TestNativePairWorkerWrongDirectionContextAndExpiredSlackQuarantine',
    'TestNativePairWorkerCleanupNeedsBothActualOriginalReleasesBeforeReuse',
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

NATIVE_PAIR_METHODS=NATIVE_PAIR_METHODS|frozenset(('TestNativePairHardwareSelectionUsesActualCurrentTrust', 'TestNativePairHardwareObservationRequiresActualBilateralPublication', 'TestNativePairHardwarePublicationFailureIsRetained'))
