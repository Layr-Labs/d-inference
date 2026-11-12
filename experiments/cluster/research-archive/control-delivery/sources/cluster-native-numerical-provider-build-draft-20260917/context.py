"""Exact private Provider/CLI source composition; no preparation on import."""
import hashlib
import importlib.util
from pathlib import Path
BASE=Path(__file__).resolve().parent
RESEARCH=BASE.parent
ELIGIBILITY=RESEARCH/'cluster-member-ready-eligibility-correction-20260917'
ELIGIBILITY_SHA='c43faeb94089f431a15f14c20f5a33060b8a16b652bbae461825a44e105a5654'
PRIOR=RESEARCH/'cluster-member-ready-eligibility-checks-20260917'
ACTOR=RESEARCH/'cluster-member-install-actor-checks-20260917'
DRIVER=RESEARCH/'cluster-native-shared-hardware-driver-draft-20260917'
DRIVER_SHA='e0d428fb6c7b7ea93d67ff6d31aad8f8ca7e47aec9d8f4918f1c0d64340cf80f'
TLS_COMPOSITION=RESEARCH/'cluster-native-shared-hardware-tls-composition-correction-20260917'
TLS_COMPOSITION_SHA='a4a149f92efffb3d75115786acd3a1c77a5adcd8e8783b86cf1d6d2a5709dc48'
NUMERICAL=RESEARCH/'qwen9b-protected-numerical-evidence-draft-20260917'
NUMERICAL_SHA='948ef71c633789e321bcf4fc1e61a58bf96edd8578ee357fda07329c4149fb4d'
ADAPTER=RESEARCH/'cluster-native-member-shared-requests-draft-20260917'
ORIGINAL=RESEARCH/'cluster-native-member-invocation-build-1-20260916'
WORKSPACE=ORIGINAL/'workspace'
OUTPUT=RESEARCH/'cluster-native-numerical-provider-checks-20260917'
OLD_HELPER=PRIOR/'helper-1'
DRAIN=RESEARCH/'cluster-owner-release-eof-drain-correction-20260917'
DRAIN_SHA='60417b284854105963be1ad2c5d4d85ea658a5f16eb9ee1ce26796cdf4812045'
path=ADAPTER/'Tests/context.py'
if hashlib.sha256(path.read_bytes()).hexdigest()!='6dadabb14514ac98e8ff7020dcb40d892c4e3fdeba464ac3b6d4d7a8b3dae23f':raise ValueError('Exact inherited context differs')
spec=importlib.util.spec_from_file_location('_numerical_inherited_context',path)
inherited=importlib.util.module_from_spec(spec);spec.loader.exec_module(inherited)
SOURCE=inherited.SOURCE
SWIFT_FILTER=inherited.SWIFT_FILTER+'|NativeHardwareDriverTests'
NATIVE_PAIR_METHODS=inherited.NATIVE_PAIR_METHODS
isolated_environment=inherited.isolated_environment
