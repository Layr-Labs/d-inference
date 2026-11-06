"""Frozen Swift-only composition; imports do not copy or compile anything."""
from pathlib import Path

BASE = Path(__file__).resolve().parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference')
UPSTREAM = BASE.parent / 'cluster-registered-member-validation-fixtures-20260916'
UPSTREAM_SHA = '0550d8fb270ac4dbef474fc0585497d7bf8c612ca35812cca6f76ac6ade2be06'
OVERLAY = BASE.parent / 'cluster-registered-member-draft-20260915'
OVERLAY_SHA = '4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965'
B_OVERLAY = BASE.parent / 'coordinator-native-pair-authorization-draft-20260916'
B_OVERLAY_SHA = '69189730ac9df0ced27006c2b00606583a20f905a7140cfc8fff5f24ff9dc500'
SWIFT_FILTER = 'ClusterMemberRegistrationTests|ClusterMemberLoopTests|DistributedStartCommandTests|DistributedStartSessionFactoryTests|CoordinatorClient|StartupPreload|EngineV2SupportedSetGateTests|MetallibHashTests|NativePairMessageTests'
NATIVE_PAIR_METHODS = (
    'publicSigningBytesMatchIndependentGoAndPythonFixture',
    'ambiguousOrUnknownPublicRecordsAreRefused',
)

ORIGINAL = BASE.parent / 'coordinator-native-pair-swift-validation-20260916'
ORIGINAL_SHA = '9a33d47e497064b6680ef513e09b5896d8f9d05462ce16e589f5548f0e01a8aa'
FAILED = BASE.parent / 'coordinator-native-pair-swift-build-1-20260916'
RETRY = FAILED / 'actor-await-correction-1'
