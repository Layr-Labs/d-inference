"""Pinned original invocation context; no source preparation at import."""
import hashlib
import importlib.util
from pathlib import Path

BASE=Path(__file__).resolve().parent
UPSTREAM=BASE.parent/'cluster-native-member-invocation-draft-20260916'
UPSTREAM_SHA='9347eaf2658a3304d1a49310ee70100b05b209f01632fc990c4fa389552cac4f'
FAILED=BASE.parent/'cluster-native-member-invocation-build-1-20260916'
RETRY=BASE.parent/'cluster-native-member-invocation-retry-1-20260917'
HELPER_SHA='8003f7d3b3850649564b1c8d4f0d630255067cb205350d04543a9d1ece2c00e1'
path=UPSTREAM/'Tests/context.py'
if hashlib.sha256(path.read_bytes()).hexdigest()!='d01d3db2af8c5420b81eff0142670a5129cddf56d2c94755ac924eacd99c6a43':raise ValueError('Original context changed')
spec=importlib.util.spec_from_file_location('_qualified_invocation_context',path)
original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
SOURCE=original.SOURCE
SWIFT_FILTER=original.SWIFT_FILTER
NATIVE_PAIR_METHODS=original.NATIVE_PAIR_METHODS
INVOCATION_METHODS=original.INVOCATION_METHODS
isolated_environment=original.isolated_environment
