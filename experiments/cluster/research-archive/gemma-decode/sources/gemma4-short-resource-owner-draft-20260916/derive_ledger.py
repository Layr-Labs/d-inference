"""Small retained-metadata replay. No model file, native allocator or device access."""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

BASE = Path(__file__).resolve().parent


def pin(path):
    raw = path.read_bytes()
    return {"path": str(path), "sizeBytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def derive_cut(cut_number):
    pins = json.loads((BASE / 'ledger-inputs.json').read_text())
    for item in pins['files']:
        if pin(Path(item['path'])) != item:
            raise ValueError('Retained metadata differs: ' + item['path'])
    rows = json.loads(Path(pins['files'][0]['path']).read_text())
    cuts = json.loads(Path(pins['files'][1]['path']).read_text())
    cut = next(x for x in cuts['cuts'] if x['cut'] == cut_number)
    if len(rows) != 1339 or sum(x['bytes'] for x in rows) != 14_467_688_508:
        raise ValueError('Text descriptor conservation differs')
    outputs = {}
    for target in ['full-reference', 'stage-0', 'stage-1']:
        rank = None if target == 'full-reference' else int(target[-1])
        selected = []
        for row in rows:
            name = row['name']
            layer = re.fullmatch(r'language_model\.model\.layers\.(\d+)\.(.+)', name)
            if layer:
                global_index = int(layer[1]); owner = 0 if global_index < cut_number else 1
                mapped = [{'rank': owner, 'localName': f'language_model.model.layers.{global_index - (0 if owner == 0 else cut_number)}.{layer[2]}'}]
            elif name.startswith('language_model.model.embed_tokens.'):
                mapped = [{'rank': r, 'localName': name} for r in (0, 1)]
            elif name == 'language_model.model.norm.weight':
                mapped = [{'rank': 1, 'localName': name}]
            else:
                raise ValueError('Unexpected non-layer source')
            if cut_number == 15 and mapped != [{k: d[k] for k in ('rank', 'localName')} for d in row['destinations']]:
                raise ValueError('Dynamic mapping differs from retained cut15 descriptor destinations')
            destinations = [{'localName': name}] if rank is None else [d for d in mapped if d['rank'] == rank]
            for destination in destinations:
                selected.append((destination['localName'], row))
        selected.sort(key=lambda x: x[0])
        count, payload = len(selected), sum(r['bytes'] for _, r in selected)
        if rank is not None and (count != cut['rankTensorCounts'][rank] or payload != cut['rankHeaderDerivedPayloadBytes'][rank]):
            raise ValueError('Exact selected-cut descriptor projection differs')
        arrays = []
        def add(name, shape, size=4):
            arrays.append({'name': name, 'bytes': math.prod(shape) * size})
        owns_head = rank != 0
        casts = head_casts = 0
        for name, row in selected:
            if name.endswith(('.scales', '.biases')) and row['dtype'] in ('F16', 'BF16'):
                embedding = name.startswith('language_model.model.embed_tokens.')
                if embedding and not owns_head:
                    continue
                size = math.prod(row['shape']) * 4
                arrays.append({'name': ('headCast:' if embedding else 'constantCast:') + name, 'bytes': size})
                if embedding: head_casts += size
                else: casts += size
        globals_ = range(30) if rank is None else range(0, cut_number) if rank == 0 else range(cut_number, 30)
        state = logical_snapshot = 0
        for g in globals_:
            full = g % 6 == 5
            h, d, slots = (2, 512, 34) if full else (8, 256, 1024)
            prefix = f'layer{g}:'
            for name in ('keys', 'values'): add(prefix + name, [slots, h, d])
            state += 2 * slots * h * d * 4
            logical_snapshot += 2 * 34 * h * d * 4
            if not full:
                for name in ('oldKeys', 'oldValues'): add(prefix + name, [slots, h, d])
                for name in ('chunkKeys', 'chunkValues'): add(prefix + name, [slots - 1 + 16, h, d])
            for name in ('position', 'capturedPosition', 'queryPosition'): add(prefix + name, [1])
            for name in ('input', 'inputNorm', 'oProjection', 'postAttention', 'attentionResidual', 'sharedPreNorm', 'sharedDown', 'sharedPostNorm', 'routerNorm', 'sparsePreNorm', 'weightedReduction', 'sparsePostNorm', 'branchSum', 'postFFNNorm', 'residualAdd', 'layerScalarOutput'):
                add(prefix + name, [16, 2816])
            for name in ('qProjection', 'qNorm', 'qRoPE', 'attentionOutput', 'attentionOutputCast'): add(prefix + name, [16, 16, d])
            for name in ('kProjection', 'kNorm', 'kRoPE', 'vNorm'): add(prefix + name, [16, h, d])
            for name in ('attentionKCopy', 'attentionVCopy'): add(prefix + name, [34, h, d])
            for name in ('attentionScores', 'attentionProbabilities'): add(prefix + name, [16, 16, 34])
            add(prefix + 'attentionMask', [16, 34], 1)
            for name in ('sharedGate', 'sharedUp', 'sharedGELU', 'sharedProduct'): add(prefix + name, [16, 2112])
            add(prefix + 'routerScale', [2816])
            for name in ('routerScores', 'routerPartition'): add(prefix + name, [16, 128])
            for name in ('topKIndices', 'topKValues', 'topKSoftmax', 'expertScaleGather', 'topKWeights'): add(prefix + name, [16, 8])
            for name in ('order', 'inverseOrder', 'inputGatherIndex', 'sortedIndices'): add(prefix + name, [16 * 8])
            for name in ('sortedInput', 'expertDown', 'unsortedOutput', 'weightedProduct'): add(prefix + name, [16 * 8, 2816])
            for name in ('expertGate', 'expertUp', 'expertGELUProduct'): add(prefix + name, [16 * 8, 704])
        for g in globals_:
            for name in ('probeKeys', 'probeValues'):
                add(f'layer{g}:' + name, [3, 2 if g % 6 == 5 else 8, 512 if g % 6 == 5 else 256])
        if rank != 1:
            add('inputIDs', [16]); add('embeddingGatherWeight', [16, 2816 // 2], 1)
            for name in ('embeddingGatherScales', 'embeddingGatherBiases'): add(name, [16, 2816 // 64])
            add('embeddingDequantized', [16, 2816])
        for name in ('residual', 'ownedResidualCopy', 'boundaryExport'): add(name, [16, 2816])
        if owns_head:
            for name in ('logits', 'float32Logits', 'softcapTemporary', 'samplingRow'): add(name, [262144])
        outputs[target] = dict(selectedTensorCount=count, selectedLogicalBytes=payload,
            largestHostTensorBytes=max(r['bytes'] for _, r in selected), persistentCastLogicalBytes=casts,
            tiedHeadTransientCastLogicalBytes=head_casts, stateLogicalBytes=state,
            hostEvidenceBytes=logical_snapshot + 2*262144*4 + 2*16*2816*4 + 1_048_576,
            namedArrayCount=len(arrays), namedLogicalBytes=sum(a['bytes'] for a in arrays), namedArrays=arrays)
        record = outputs[target]
        record['initialRequiredActualFreeLogicalFloorBytes'] = max(6 * 1024**3,
            payload + 2 * record['largestHostTensorBytes'] + (8 * 1024**2 + 16384)
            + record['namedLogicalBytes'] + record['hostEvidenceBytes'] + 4 * 1024**3)
        record['initialAllocatorFutureReserveLogicalFloorBytes'] = payload + record['largestHostTensorBytes'] + record['namedLogicalBytes'] + 2 * 1024**3
    return {'schema': 'gemma4_short_logical_allocation_replay_v1', 'cut': cut_number,
        'promptTokens': 32, 'chunkTokens': 16, 'outputTokens': 2, 'maximumTokens': 34,
        'existingPhysicalFloorBytes': 6 * 1024**3, 'existingLoadingHeadroomBytes': 4 * 1024**3,
        'existingAllocatorHeadroomBytes': 2 * 1024**3, 'targets': outputs,
        'actualAllocatorBoundsObserved': False, 'nativeExecution': False, 'payloadRead': False,
        'wholeProcessPeakBoundEstablished': False, 'servingFloorEstablished': False}


def derive():
    cases = {str(cut): derive_cut(cut) for cut in (8, 10, 12, 15)}
    result = cases['10']
    result['candidateCuts'] = {cut: {name: {k: v for k, v in row.items() if k != 'namedArrays'}
        for name, row in case['targets'].items()} for cut, case in cases.items()}
    result['cutSelection'] = '10: prospective ingress choice with more logical admission margin than12/15; actual rounded admission remains authoritative'
    result['assumedCurrentFreeBytes'] = None
    return result


def main():
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--write', type=Path)
    action.add_argument('--verify', type=Path)
    args = parser.parse_args()
    result = derive()
    if args.write:
        with args.write.open('x') as output:
            json.dump(result, output, indent=2, sort_keys=True); output.write('\n')
    elif json.loads(args.verify.read_text()) != result:
        raise ValueError('Retained ledger differs from exact metadata replay')
    print(json.dumps({'passed': True, 'metadataOnly': True, 'targets': {k: {n: v for n, v in row.items() if n != 'namedArrays'} for k, row in result['targets'].items()}}, sort_keys=True))


if __name__ == '__main__':
    main()
