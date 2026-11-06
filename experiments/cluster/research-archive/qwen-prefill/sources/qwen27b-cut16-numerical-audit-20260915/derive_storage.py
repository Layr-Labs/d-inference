"""Expected cut16 storage from pinned source descriptors and actual pure Plan metadata."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
PRIOR = ROOT / 'qwen27b-expected-generation-identity-20260915'
METADATA = ROOT / 'qwen27b-cut16-owner-proposal-20260915/build-1/metadata-evidence/stdout'
sys.path.insert(0, str(PRIOR))
from recorded_math import canonical, digest, require


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=digest(raw))


prior = module('qualified_prior_identity', PRIOR / 'derive_identity.py')
mapping_source = ROOT / 'qwen27b-resident-alternative-cut-audit-20260915/derive_cuts.py'
mapping = module('reviewed_cut_mapping', mapping_source).mapping


def commitment_for(report, metadata, cut):
    require(type(cut) is int and cut in (16, 32), 'Only explicit cut16 or cut32 replay')
    require(metadata['modelID'] == report['model'] == 'registered_qwen38_27b'
            and metadata['stageCut'] == cut, 'Wrong model/cut metadata')
    for report_key, metadata_key in [('verifiedAggregateSHA256', 'artifactSHA256'),
            ('configurationSHA256', 'configurationSHA256'), ('manifestSHA256', 'manifestSHA256')]:
        require(report[report_key] == metadata[metadata_key], 'Source/metadata identity differs')
    tensors = report['sourceTensors']
    require(len(tensors) == 1847 and len({x['sourceName'] for x in tensors}) == 1847,
            'Source tensor inventory duplicated or missing')
    require(digest(canonical(tensors)) == report['sourceTensorManifestSHA256'], 'Source descriptors changed')
    require(sum(x['byteCount'] for x in tensors) == 15_132_802_048, 'Source byte conservation differs')
    active_by_rank = [[], []]
    for tensor in tensors:
        rank, local = mapping(tensor['sourceName'], cut)
        active_by_rank[rank].append(dict(sourceName=tensor['sourceName'], localName=local,
            **{key: tensor[key] for key in ['shape', 'sourceDType', 'loadedDType', 'byteCount']}))
    summaries = []
    for rank, active in enumerate(active_by_rank):
        active.sort(key=lambda x: x['localName'])
        require(len({x['localName'] for x in active}) == len(active), 'Local tensor names overlap')
        # Exact source implementation depends on rank, H and activation dtype,
        # not layer count. This is expected metadata, not a cut16 constructor claim.
        inert = [copy.deepcopy(x) for m in report['stages'][rank]['installedLazyInertModules'] for x in m['parameters']]
        require(len(inert) == (2 if rank == 0 else 1)
                and all(x['dtype'] == 'bfloat16' and x['byteCount'] == 10_240 for x in inert),
                'Rank-specific inert placeholder geometry differs')
        active_layout = [f"{x['localName']}:{x['loadedDType']}:{x['shape']}" for x in active]
        inert_layout = [f"{x['localName']}:{x['dtype']}:{x['shape']}" for x in inert]
        summary = dict(stageIndex=rank, stagePlanSHA256=metadata['stagePlanSHA256'][rank],
            constructionConfigurationSHA256=metadata['constructionConfigurationSHA256'][rank],
            activeMappingSHA256=digest(canonical(active)),
            activeParameterLayoutSHA256=digest('\n'.join(sorted(active_layout)).encode()),
            parameterLayoutSHA256=digest('\n'.join(sorted(active_layout + inert_layout)).encode()),
            loadedTensorBytes=sum(x['byteCount'] for x in active), activeTensorCount=len(active),
            inertTensorBytes=sum(x['byteCount'] for x in inert), inertTensorCount=len(inert))
        require(summary['activeTensorCount'] == metadata['canonicalCounts'][rank]
                and summary['loadedTensorBytes'] == metadata['activeBytes'][rank],
                'Actual pure storage requirement and expected mapping disagree')
        summaries.append(summary)
    commitment = dict(schemaVersion=1, verifiedAggregateSHA256=report['verifiedAggregateSHA256'],
        sourceConfigurationSHA256=report['configurationSHA256'], planSHA256=metadata['planSHA256'],
        sourceTensorManifestSHA256=report['sourceTensorManifestSHA256'], sourceModelTensorBytes=report['sourceTensorBytes'],
        largestSourceTensorBytes=report['largestSourceTensorBytes'], sourceTensorCount=report['sourceTensorCount'],
        canonicalTensorCount=len(tensors), bf16ConversionEnabled=True, stages=summaries)
    return commitment, active_by_rank


def derive():
    require(pin(METADATA)['sha256'] == '4c22d847bb83991a37d83a9c97be94eb8152f5341c8deaa4b3bf6e677eb6eeeb',
            'Actual cut16 metadata output changed')
    values, saved = prior.load_inputs()
    original = prior.derive(values)  # Reuse every prior constructor/audit/layout/environment check.
    report = values['constructor.stdout.jsonl']
    replay, replay_active = commitment_for(report, values['recording-metadata.json'], 32)
    require(canonical(replay) == canonical(original['storageCommitment']), 'Cut32 full commitment replay differs')
    require(all(canonical(active) == canonical(report['stages'][rank]['expectedActiveTensors'])
                for rank, active in enumerate(replay_active)), 'Cut32 complete mapping replay differs')
    metadata = json.loads(METADATA.read_bytes())
    commitment, active = commitment_for(report, metadata, 16)
    require([len(x) for x in active] == [463, 1384], 'Wrong cut16 ownership')
    require(metadata['generationProfileSHA256'] == values['recording-metadata.json']['generationProfileSHA256'],
            'Generation profile changed')
    for name, before in saved.items():
        require(prior.snapshot(PRIOR / 'inputs' / name, 2 * 1024 * 1024, keep=False) == dict(before, raw=None),
                'Prior evidence input changed')
    value = dict(schema='qwen27b_cut16_expected_generation_identity_v1',
        storageCommitment=commitment, storageCommitmentSHA256=digest(canonical(commitment)),
        arithmeticEnvironment=original['arithmeticEnvironment'], arithmeticSHA256=original['arithmeticSHA256'],
        priorCut32StorageCommitmentSHA256=original['storageCommitmentSHA256'],
        exactPriorCut32CommitmentAndAll1847MappingsReplayed=True,
        metadata=pin(METADATA), source='pinned prior full descriptors plus actual cut16 pure Plan and source-qualified mapping',
        actualCut16ConstructorObserved=False, actualLoadedInventoryEstablished=False,
        tensorPayloadRead=False, candidateOrReferenceOutputsRead=False, numericalQualification=False,
        inputs=[pin(PRIOR / 'derive_identity.py'), pin(PRIOR / 'recorded_math.py'), pin(PRIOR / 'snapshot.py'),
                pin(mapping_source)] + [pin(PRIOR / 'inputs' / name) for name in saved])
    return value, active


def main():
    value, active = derive()
    for name, result in [('expected-identity.json', value), ('expected-active-mappings.json', active)]:
        with (BASE / name).open('xb') as stream:
            stream.write(canonical(result) + b'\n')
    print(json.dumps(dict(prepared=True, storageCommitmentSHA256=value['storageCommitmentSHA256'],
                         priorCut32Replay=True, cut16Counts=list(map(len, active)))))


if __name__ == '__main__':
    main()
