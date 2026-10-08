"""CPU fakes from a pinned OLD equal-cut record, never a future candidate.

The new cut's inventory/plan are prospective metadata. Rebinding these old
numerical rows creates a coherent parser fixture, not a native 12+20 result.
"""
import copy
from pathlib import Path
from cut12_expected import canonical, digest, parse, require
import qwen_layer_stage_cut12_audit as oracle

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
OLD_STDOUT = ROOT/'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt'
OLD_SHA = 'dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551'


def old_records():
    raw = OLD_STDOUT.read_bytes()
    require(len(raw) <= 64*1024**2 and digest(raw) == OLD_SHA, 'Historical CPU fixture changed')
    return [parse(line) for line in raw.splitlines()]


def baseline_fingerprint(baseline):
    hashes = []
    for row in baseline['frames']:
        f = row['frame']
        logits = row.get('logits')
        logical = logits['logicalBytesSHA256'] if logits else 'no-logits'
        text = ('qwen-recorded-frame-v1\n'
            + f"{f['sequence']}|{f['phase']}|{f['tokenOffset']}|{f['tokenCount']}|{str(f['finalPromptChunk']).lower()}\n"
            + f"tokens={row['committedTokens']}\n{row['outputKind']}|{row['outputShape']}|{row['outputDType']}\n"
            + row['state']['fingerprint']+'\n'+logical)
        hashes.append(digest(text.encode()))
    return digest(('qwen-layer-stage-baseline-v1\n'+baseline['request']['fingerprint']+'\n'
        +digest(canonical(baseline['source']))+'\n'+'\n'.join(hashes)).encode())


def refresh_storage(checkpoint, report):
    summaries = []
    for receipt in report['stageLoads']:
        entries = receipt['activeTensors']
        inert = [dict(p,loadedDType=p['dtype']) for module in receipt['inertModules'] for p in module['parameters']]
        receipt['activeMappingSHA256'] = digest(canonical(entries))
        receipt['activeParameterLayoutSHA256'] = oracle.layout(entries)
        receipt['parameterLayoutSHA256'] = oracle.layout(entries+inert)
        receipt['loadedTensorBytes'] = sum(t['byteCount'] for t in entries)
        receipt['largestHostTensorBytes'] = max(t['byteCount'] for t in entries)
        receipt['inertTensorBytes'] = sum(t['byteCount'] for t in inert)
        summary = {key:receipt[key] for key in ['stageIndex','constructionConfigurationSHA256','stagePlanSHA256',
            'activeMappingSHA256','activeParameterLayoutSHA256','parameterLayoutSHA256','loadedTensorBytes','inertTensorBytes']}
        summary.update(activeTensorCount=len(entries),inertTensorCount=len(inert))
        summaries.append(summary)
    common = copy.deepcopy(report['stageLoads'][0]['storageCommitment'])
    common['planSHA256'] = checkpoint['baseline']['source']['planSHA256']
    common['stages'] = summaries
    value = digest(canonical(common))
    for receipt in report['stageLoads']:
        receipt['storageCommitment'] = copy.deepcopy(common)
        receipt['storageCommitmentSHA256'] = value
    report['comparison']['stageStorageCommitmentSHA256'] = value


def fake_pair(expected):
    checkpoint, report = old_records()
    checkpoint['baseline']['source']['planSHA256'] = expected['planSHA256']
    report['comparison']['source'] = copy.deepcopy(checkpoint['baseline']['source'])
    for index, receipt in enumerate(report['stageLoads']):
        receipt['planSHA256'] = expected['planSHA256']
        for key in ['activeTensors','constructionConfigurationSHA256','stagePlanSHA256']:
            receipt[key] = copy.deepcopy(expected['stages'][index][key])
    refresh_storage(checkpoint,report)
    value = baseline_fingerprint(checkpoint['baseline'])
    checkpoint['baseline']['fingerprint'] = value
    report['comparison']['baselineEvidenceSHA256'] = value
    return checkpoint, report


def state_hash(state):
    lines = [f"{e['globalLayerIndex']}|{e['component']}|{e['shape']}|{e['dtype']}|{e['byteCount']}|{e['sha256']}" for e in state['entries']]
    return digest(('cbv2-owned-state-v1\ntokens='+str(state['committedTokens'])+'\n'+'\n'.join(lines)).encode())
