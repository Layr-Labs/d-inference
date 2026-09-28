"""Frozen member overlay and bounded validation inputs; importing does no IO."""
from pathlib import Path
BASE = Path(__file__).resolve().parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference')
OVERLAY = BASE.parent / 'cluster-registered-member-draft-20260915'
OVERLAY_SHA = '4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965'
GO = '/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go'
GO_SHA = 'c812de5f1e8307431c5bce8ebc4887c180827abc5834a72cd640a8a14200a93b'
GO_PACKAGES = ('coordinator/registry', 'coordinator/protocol', 'coordinator/api')
GO_FILTER = '^Test(VerifiedPair|ClusterMember|MemberRole)'
SWIFT_FILTER = 'ClusterMemberRegistrationTests|ClusterMemberLoopTests|DistributedStartCommandTests|DistributedStartSessionFactoryTests|CoordinatorClient|StartupPreload|EngineV2SupportedSetGateTests|MetallibHashTests'
