"""Exact shared adapter and qualified invocation workspace; no materialization."""
import hashlib
import importlib.util
from pathlib import Path
BASE=Path(__file__).resolve().parent
ADAPTER=BASE.parent/'cluster-native-member-shared-requests-draft-20260917'
ADAPTER_SHA='1e8019ad6af9314979d5182bf61eb47671f9b22d5eb176b1cd97345c805e7c38'
CORRECTION=BASE.parent/'cluster-native-member-shared-requests-cancellation-correction-20260917'
CORRECTION_SHA='4662ba2a236c3bd8900b2bd607ebcd3249ced8b2a9631e0f7d8181827107fea3'
PRIOR=BASE.parent/'cluster-native-member-invocation-retry-1-20260917'
ORIGINAL=BASE.parent/'cluster-native-member-invocation-build-1-20260916'
WORKSPACE=ORIGINAL/'workspace'
OUTPUT=BASE.parent/'cluster-native-member-shared-requests-swift-checks-2-20260917'
path=ADAPTER/'Tests/context.py'
if hashlib.sha256(path.read_bytes()).hexdigest()!='6dadabb14514ac98e8ff7020dcb40d892c4e3fdeba464ac3b6d4d7a8b3dae23f':raise ValueError('Frozen adapter context changed')
spec=importlib.util.spec_from_file_location('_shared_requests_context',path)
original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
SOURCE=original.SOURCE
SWIFT_FILTER=original.SWIFT_FILTER
INVOCATION_METHODS=original.INVOCATION_METHODS+('cancelBetweenDecodeAndFollowerDeliveryNeverEnqueuesCommand',)
NATIVE_PAIR_METHODS=original.NATIVE_PAIR_METHODS
isolated_environment=original.isolated_environment
