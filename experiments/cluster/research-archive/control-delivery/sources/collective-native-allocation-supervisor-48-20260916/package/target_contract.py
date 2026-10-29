"""Closed allocation catalog; artifact binding is supplied only after build PASS."""
from pathlib import Path
from binding_common import parse
from allocation_result import CASES, validate_result

REMOTE = '/Users/developer/DarkbloomDev/collective-native-allocation-check-48-20260916'
ARTIFACT = parse((Path(__file__).parent/'native-binding.json').read_bytes())
BUNDLE = ARTIFACT['bundleSHA256']
SOURCE = ARTIFACT['sourceSnapshotSHA256']
METALLIB = ARTIFACT['metallibSHA256']
PAGED = ARTIFACT['pagedSHA256']
JOBS = {case_id: dict(product='CollectiveAllocationCheck',
    runArguments=['run-resource-case', case_id], processAlarmSeconds=60,
    sha256=ARTIFACT['nativeSHA256']) for case_id in CASES}
