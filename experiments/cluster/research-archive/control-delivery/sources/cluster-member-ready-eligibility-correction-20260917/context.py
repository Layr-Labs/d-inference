"""One owner-Service correction over the actual actor-corrected private workspace."""
from pathlib import Path
from upstream_context import ADAPTER,ADAPTER_SHA,CORRECTION_SHA,WORKSPACE,SOURCE,SWIFT_FILTER,INVOCATION_METHODS,NATIVE_PAIR_METHODS,isolated_environment
BASE=Path(__file__).resolve().parent
ACTOR=BASE.parent/'cluster-member-install-actor-correction-20260917'
ACTOR_SHA='0f8d48a333f6e6c4be2a0be373ad28ef82bce06b33a792ef243e311f448053cb'
PRIOR=BASE.parent/'cluster-member-install-actor-checks-20260917'
OUTPUT=BASE.parent/'cluster-member-ready-eligibility-checks-20260917'
OLD_HELPER=BASE.parent/'cluster-native-member-shared-requests-swift-checks-2-20260917/helper-1'
