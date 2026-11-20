"""Read-only equivalence of retained prior/current commitment and inventory source."""
from pathlib import Path
import hashlib
import json

BASE = Path(__file__).resolve().parent
WHOLE = ['PreparedQwenLayerStage.swift', 'QwenLayerStageInert.swift',
         'QwenLongPrefillArithmeticEnvironment.swift', 'QwenLayerStagePlan.swift',
         'PreparedQwenLayerSource.swift', 'CanonicalJSON.swift']
BLOCKS = [('QwenLayerStageInventoryTypes.swift', 'struct QwenLayerStageStorageCommitment'),
          ('QwenLayerStageInventoryTypes.swift', 'struct QwenStageStorageSummary'),
          ('VerifiedQwenLayerStageLoading.swift', 'func qwenLayerStageStorageCommitment')]


def pin(raw):
    return dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def block(raw, prefix):
    start = raw.index(prefix.encode())
    opening = raw.index(b'{', start)
    depth = 0
    for end in range(opening, len(raw)):
        if raw[end] == ord('{'): depth += 1
        elif raw[end] == ord('}'): depth -= 1
        if depth == 0: return raw[start:end+1]
    raise ValueError('Unclosed declaration')


def verify():
    lineage = json.loads((BASE/'source-lineage.json').read_bytes())
    for row in lineage:
        raw = (BASE/row['copy']).read_bytes()
        if pin(raw) != row['pin'] or raw != Path(row['source']).read_bytes():
            raise ValueError('Pinned source differs: ' + row['copy'])
    result = []
    for name in WHOLE:
        old, current = ((BASE/'sources'/kind/name).read_bytes() for kind in ('prior','current'))
        if old != current: raise ValueError('Whole source changed: ' + name)
        result.append(dict(file=name, scope='whole file', **pin(current)))
    for name, symbol in BLOCKS:
        old, current = (block((BASE/'sources'/kind/name).read_bytes(), symbol) for kind in ('prior','current'))
        if old != current: raise ValueError('Declaration changed: ' + symbol)
        result.append(dict(file=name, scope=symbol, **pin(current)))
    return dict(schema='qwen27b_expected_identity_source_equivalence_v1', identical=result,
        sourceCopies=len(lineage), sourceCompilationOrNativeExecution=False,
        currentSourceRuntimeAttestation=False,
        limitation='Declaration extraction is a literal brace count, valid for these reviewed declarations; it is not a general Swift parser.')


if __name__ == '__main__': print(json.dumps(verify(),sort_keys=True,indent=2))
