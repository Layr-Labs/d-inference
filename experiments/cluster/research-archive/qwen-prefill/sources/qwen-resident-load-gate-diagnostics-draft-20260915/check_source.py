"""Check the bounded observation-only source delta; this does not compile Swift."""
from pathlib import Path
import difflib
import hashlib
import json

ROOT = Path(__file__).resolve().parent
RELATIVE = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentLoading.swift'
OLD = ROOT / 'originals/QwenResidentLoading.swift'
NEW = ROOT / 'proposed' / RELATIVE


def main():
    old, new = OLD.read_text(), NEW.read_text()
    assert hashlib.sha256(old.encode()).hexdigest() == '4d440e9f9b2440f2c760262f95172d0f85d09683e43176b74ed165093e053cb5'
    restored = new
    for after, before in [
        ('try observe(phase: "initial")', 'try observe()'),
        ('func observe(phase: String = "materializer-check") throws {', 'func observe() throws {'),
        ('try observe(phase: "before-read"); next += 1', 'try observe(); next += 1'),
        ('try observe(phase: "finish")', 'try observe()'),
        ('            let activeBytes = Memory.activeMemory\n            let cacheBytes = Memory.cacheMemory\n'
         '            let allocator = try QwenLongPrefillCheckedBytes.sum([activeBytes, cacheBytes,',
         '            let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,'),
    ]:
        assert restored.count(after) == 1
        restored = restored.replace(after, before)
    start = restored.index('            let freeAdmitted = os.actualFreeBytes >= required')
    end = restored.index('\n            }\n        } catch { failed = true; throw error }', start)
    replaced = restored[start:end]
    assert 'freeAdmitted ? Memory.memoryLimit : nil' in replaced
    assert 'guard freeAdmitted, let allocatorLimit, allocatorLimit >= allocator else {' in replaced
    assert replaced.count('Memory.memoryLimit') == 1
    restored = restored[:start] + ('            guard os.actualFreeBytes >= required, Memory.memoryLimit >= allocator else {\n'
        '                throw ProbeError("Resident load exceeds current actual-free or allocator policy")') + restored[end:]
    assert restored == old
    # Native WorkerMain caps error text at 4096 bytes. Even maximal signed-Int
    # values in every declared diagnostic field fit comfortably within that cap.
    maximum = str(2**63 - 1)
    message = ('Resident load exceeds current actual-free or allocator policy; phase=materializer-check; '
        + '; '.join(name + '=' + maximum for name in [
            'readAdmitted', 'activeCount', 'actualFreeBytes', 'requiredFreeBytes', 'remainingBoundBytes',
            'hostTensorBytes', 'scratchBytes', 'activeBytes', 'cacheBytes', 'allocatorRequiredBytes', 'allocatorLimitBytes']))
    assert len(message.encode()) + 128 < 4096
    patch = ''.join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
        fromfile='a/' + RELATIVE, tofile='b/' + RELATIVE))
    (ROOT / 'runtime.patch').write_text(patch)
    report = dict(schema='resident_load_gate_diagnostic_source_check_v1', passed=True,
        originalSHA256=hashlib.sha256(old.encode()).hexdigest(), proposedSHA256=hashlib.sha256(new.encode()).hexdigest(),
        patchSHA256=hashlib.sha256(patch.encode()).hexdigest(), exactInverseRestoresOriginal=True,
        formulasFloorsChecksPoisonAndMaterializerBodyUnchanged=True,
        allocatorLimitReadRemainsShortCircuited=True, diagnosticUpperBoundBytes=len(message.encode()) + 128,
        nativeTypecheckPerformed=False, nativeModelOrRemoteExecution=False)
    (ROOT / 'source-checks.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
