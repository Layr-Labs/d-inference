"""Only the CLI source changes; reuse the exact private workspace and actual helper."""
from pathlib import Path
from upstream_context import ADAPTER,ADAPTER_SHA,CORRECTION_SHA,WORKSPACE,SOURCE,SWIFT_FILTER,INVOCATION_METHODS,NATIVE_PAIR_METHODS,isolated_environment
BASE=Path(__file__).resolve().parent
PRIOR=BASE.parent/'cluster-native-member-shared-requests-swift-checks-2-20260917'
OUTPUT=BASE.parent/'cluster-member-install-actor-checks-20260917'
HELPER=PRIOR/'helper-1'
