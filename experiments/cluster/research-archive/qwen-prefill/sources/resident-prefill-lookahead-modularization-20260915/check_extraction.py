#!/usr/bin/env python3
"""Exact source-preserving split, plus frozen lookahead source checks."""
from pathlib import Path
import hashlib
import json

draft = Path(__file__).resolve().parent
integration = json.loads((draft / 'integration.json').read_bytes())
frozen = Path(integration['base_overlay'])
runtime = Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
manifest_bytes = (frozen / 'manifest.json').read_bytes()
assert hashlib.sha256(manifest_bytes).hexdigest() == integration['base_manifest_sha256']
for row in json.loads(manifest_bytes)['members']:
    assert hashlib.sha256((frozen / row['path']).read_bytes()).hexdigest() == row['sha256'], row['path']
old = (frozen / 'proposed' / runtime / 'QwenLayerStageGenerationDriver.swift').read_text()
assert (draft / 'originals/QwenLayerStageGenerationDriver.swift').read_text() == old
driver = (draft / 'proposed' / runtime / 'QwenLayerStageGenerationDriver.swift').read_text()
producer = (draft / 'proposed' / runtime / 'QwenGenerationLookaheadProducer.swift').read_text()
start = old.index('/// One native prepared slot plus one CPU pending ticket.')
end = old.index('private func requireGenerationSource(', start)
block = old[start:end]
assert driver == old[:start] + old[end:]
assert producer == 'import Foundation\nimport MLX\n\n' + block.replace(
    'private final class QwenGenerationLookaheadProducer', 'final class QwenGenerationLookaheadProducer', 1)
assert driver[:start] + producer.split('import MLX\n\n', 1)[1].replace(
    'final class QwenGenerationLookaheadProducer', 'private final class QwenGenerationLookaheadProducer', 1) + driver[start:] == old
assert 'public ' not in producer and 'open ' not in producer
assert sum(p.read_text().count('final class QwenGenerationLookaheadProducer')
           for p in (draft / 'proposed').rglob('*.swift')) == 1

# Replay the exact existing preservation checker against the shortened driver.
# The only other rewrite redirects its output into this new draft; frozen inputs
# and the original checker are never written.
source = (frozen / 'check_source.py').read_text()
find = "new = (proposed/'QwenLayerStageGenerationDriver.swift').read_text()"
assert source.count(find) == 1
source = source.replace(find, 'new = Path(' + repr(str(draft / 'proposed' / runtime / 'QwenLayerStageGenerationDriver.swift')) + ').read_text()', 1)
find = "(draft/'source-checks.json').write_text"
assert source.count(find) == 1
source = source.replace(find, '(Path(' + repr(str(draft / 'records/frozen-source-replay.json')) + ')).write_text', 1)
# The separately reviewed capability promotion moved this exact SHA body out
# of model construction. Prefer that focused helper when present; the frozen
# equality check still compares the actual body with its saved CPU extraction.
helper = Path('/Users/developer/DarkbloomDev/d-inference') / runtime / 'ClusterMetadataHashing.swift'
if helper.exists():
    find = "(repo/runtime/'QwenModelConstruction.swift').read_text()"
    assert source.count(find) == 1
    source = source.replace(find, 'Path(' + repr(str(helper)) + ').read_text()', 1)
exec(compile(source, str(frozen / 'check_source.py'), 'exec'), {'__file__': str(frozen / 'check_source.py'), '__name__': '__main__'})
result = {
    'schema': 'private_lookahead_exact_extraction_v1', 'passed': True,
    'base_manifest_sha256': integration['base_manifest_sha256'],
    'original_driver_lines': len(old.splitlines()), 'new_driver_lines': len(driver.splitlines()),
    'producer_lines': len(producer.splitlines()),
    'class_body_and_all_methods_byte_exact': True, 'remaining_driver_byte_exact': True,
    'full_original_driver_reconstructed_exactly': True, 'new_public_surface': False,
    'scope_change': 'top-level producer class private -> internal only',
    'native_typecheck_performed': False,
    'frozen_preservation_check_count': json.loads((draft / 'records/frozen-source-replay.json').read_bytes())['passed'],
    'sources': {str(p.relative_to(draft)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((draft / 'proposed').rglob('*.swift'))},
}
(draft / 'records/extraction.json').write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
print(json.dumps(result, sort_keys=True))
