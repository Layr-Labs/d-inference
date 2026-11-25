"""Private invocation source composition; importing performs no materialization."""
import hashlib
import json
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference')
A = BASE.parent / 'cluster-native-key-prelude-validation-3-20260916/source'
A_SHA = '61f28887e6165c6f488071882868216c6e92bb1f1f6f81cec826c7de0349c5bf'
SWIFT_FILTER = 'ClusterMemberRegistrationTests|ClusterMemberLoopTests|DistributedStartCommandTests|DistributedStartSessionFactoryTests|CoordinatorClient|StartupPreload|EngineV2SupportedSetGateTests|MetallibHashTests|NativePairMessageTests|NativePairMemberInvocationTests|NativePairMemberControlTests|NativePairMemberMeshTests|ClusterConfigurationTests|ClusterNativeMemberAttachmentTests|NativePairSharedRequestTests'
NATIVE_PAIR_METHODS = ('publicSigningBytesMatchIndependentGoAndPythonFixture', 'ambiguousOrUnknownPublicRecordsAreRefused')
INVOCATION_METHODS = (
    'workerPacketHasIndependentCanonicalBytes',
    'workerPacketRejectsDirectionContextTruncationAndLimits',
    'requestDeadlinesUseOriginalLifetimeSlackWithoutTransitRestart',
    'requestAdapterKeepsExactNativeWorkload',
    'protectedReadyRequiresExactBindingAndActualChargedCapacity',
    'retainedViewPreservesSequenceAndNeverInfersCleanup',
    'omissionRetainsExactLegacyConfigurationBytes',
    'savedNativeChoiceRoundTripsWithBothLocalRanks',
    'attachmentRefusesUnknownNullSecretsAndMalformedPins',
    'policyModelAndEveryRuntimeCommitmentAreBoundToSavedSetup',
    'protectedSetupCannotSelectOrdinarySessionRoute',
    'protectedDescriptionRequiresExactProducerContractAndSavedDigest',
    'meshPublicVectorAndClosedBoundsMatchGo',
    'onlyCombinedOwnerProfileAdmitsExtendedPublicSequence',
    'actualMeshFourRoundsUseAuthenticatedSocketAndRetireWithoutReady',
    'meshCancellationJoinsActualNativeOwnersAtPendingRound',
    'meshWrongLocalEchoClosesControlAndNeverReturnsCapacity',
    'combinedMeshOwnerStillRefusesNativeReady',
    'actualBilateralNativePreludeRequiresCommitAndReleasesOnlyAfterOwners',
    'committedCancellationWaitsForActualNativeExitAndOwnerLeaseRelease',
    'keyOnlyOwnerRejectsActualNativeReadyInsteadOfPublishingModelCapacity',
    'lostCommittedConnectionQuarantinesDespiteLocalCleanupAndRejectsReplacement',
    'pendingCancellationNeverLaunchesAndFreshConnectionCannotReplayEpoch',
    'publicWebSocketRoleAckDoesNotAuthorizeNativeInvocationWithoutTLS',
    'exactPreparationDeadlineRefusesDelayedStartWithoutLaunching',
    'approvalAndOriginalDeadlineBindingsRejectSubstitutionAndOverflow',
    'writerAcquisitionExpiresWhileSignerIsBlockedWithoutPublishing',
    'stalledHelloSignerCannotDelayActualNativeCleanupOrEnableReleaseOnNewConnection',
)

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(path, value): Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')

def verify():
    for root, expected in [(A, A_SHA), (BASE, None)]:
        if expected and sha(root / 'manifest.json') != expected: raise ValueError('Upstream freeze differs')
        for row in json.loads((root / 'manifest.json').read_text())['files']:
            path = root / row['path']
            if path.is_symlink() or sha(path) != row['sha256']: raise ValueError('Frozen member differs: ' + str(path))
    for source in json.loads((BASE / 'upstream-freezes.json').read_text()):
        root = Path(source['root'])
        if sha(root / 'manifest.json') != source['sha256']: raise ValueError('Lineage manifest differs')
        for item in json.loads((root / 'manifest.json').read_text())['files']:
            if sha(root / item['path']) != item['sha256']: raise ValueError('Lineage member differs')
    for row in json.loads((BASE / 'context-pins.json').read_text()):
        if sha(row['path']) != row['sha256']: raise ValueError('Integration context differs: ' + row['path'])
    integration = json.loads((BASE / 'integration.json').read_text())
    for row in integration['files']:
        path = SOURCE / row['path']
        observed = sha(path) if path.exists() else None
        if observed != row['mainSHA256'] or path.is_symlink(): raise ValueError('MAIN preimage differs: ' + row['path'])
        if sha(row['sourcePath']) != row['proposedSHA256']: raise ValueError('Overlay source differs')
    return integration

def isolated_environment():
    keep = ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT')
    selected = {key: os.environ[key] for key in keep if key in os.environ}
    os.environ.clear(); os.environ.update(selected)
