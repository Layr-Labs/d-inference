#!/usr/bin/env python3
"""Source/byte checks only; no Swift compiler, model payload or native process."""
from pathlib import Path
import difflib
import hashlib
import json
import re

D = Path(__file__).resolve().parent

def require(value, message):
    if not value:
        raise AssertionError(message)

def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]

def normalized_tail(text):
    start = text.index('        // Full-width layer stages')
    end = text.rindex('        return loaded\n') + len('        return loaded\n')
    body = '\n'.join(line[4:] if line.startswith('    ') else line for line in text[start:end].split('\n'))
    return body.replace('try error.check()', 'try check()').replace('label: directory.lastPathComponent', 'label: label')

def validate(files, originals):
    old = originals['VerifiedQwenLayerStageBaseline.swift']
    finish = files['QwenVerifiedBaselineFinishing.swift']
    body = finish[finish.index('    // Full-width layer stages'):finish.rindex('}\n')]
    require(body == normalized_tail(old), 'full finishing differs from exact original body')
    prefix = old[:old.index('        // Full-width layer stages')]
    proposed = files['VerifiedQwenLayerStageBaseline.swift']
    require(proposed.startswith(prefix), 'legacy baseline preflight/load prefix changed')
    expected = prefix + '''        return try finishVerifiedQwenLayerStageBaseline(model: model,
            originalConfiguration: originalConfiguration, receipt: receipt,
            expectedAggregateSHA256: expectedAggregateSHA256, label: directory.lastPathComponent,
            layers: layers, hidden: hidden, vocabulary: vocabulary, namespace: namespace,
            check: { try error.check() })
    }
}
'''
    require(proposed == expected, 'legacy baseline wrapper differs beyond exact finishing extraction')

    full = files['QwenDenseShortReferenceLoading.swift']
    previous = originals['QwenDenseShortReferenceLoading.swift']
    require(full[:full.index('private enum QwenDenseShortReferenceOperation')] ==
            previous[:previous.index('/// Future recording stays')], 'full private gate changed')
    require(between(full, '    let metadata = admission.metadata, plan = metadata.plan', '    weak var retiredModel') ==
            between(previous, '    let metadata = admission.metadata, plan = metadata.plan', '    weak var retiredModel'), 'full admission prefix changed')
    require(between(full, '                let model = try constructQwenModel', '                    var memory:') ==
            between(previous, '                let model = try constructQwenModel', '                    let observations = try gate.finish()'), 'full setup, budget or materializer changed')
    for token in ['private enum QwenDenseShortReferenceOperation { case loadOnly, record }',
                  'var memory: [QwenStageMemoryObservation]? = nil',
                  'case .loadOnly: baseline = nil',
                  'case .record:\n                        memory =',
                  'request: admission.request, check: checked)',
                  'resources: observations, memory: memory ?? [before, QwenStageMemoryObservation("short_full_reference_payload_loaded")]',
                  'operation: .loadOnly, check: check)', 'operation: .record, check: check)']:
        require(token in full, 'full closed operation or load-only order changed: ' + token)
    require(full.index('let observations = try gate.finish()') < full.index('resources: observations, memory: memory ??'), 'default final memory observation precedes gate finish')
    require(between(full, '                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()', '                return QwenDenseShortReferenceReleased') ==
            between(previous, '                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()', '                return QwenDenseShortReferenceLoadReport'), 'full file/cache/resource retirement order changed')
    require(between(full, '            } catch {\n                let primary = error', '/// Existing loading-only surface:') ==
            previous[previous.index('            } catch {\n                let primary = error'):] + '\n', 'full native-primary and cleanup paths changed')

    pair = files['QwenDenseShortPairLoading.swift']
    previous = originals['QwenDenseShortPairLoading.swift']
    require(pair[:pair.index('private enum QwenDenseShortPairOperation')] == previous[:previous.index('/// Both models are private')], 'pair private gate changed')
    setup = between(pair, '    let metadata = admission.metadata, plan = metadata.plan', '                    var loads:')
    setup = setup.replace('let result: QwenDenseShortPairOwnerResult', 'let result: QwenDenseShortPairLoadResult')
    require(setup == between(previous, '    let metadata = admission.metadata, plan = metadata.plan', '                    var loads:'), 'both stage inventories, Q gate or explicit model lifetime changed')
    loop = between(pair, '                    for index in [0, 1] {', '                    try prepared.source.prepared.checkpoint.checkUnchanged(); try check()')
    loop = loop.replace('                        if case .compare = operation { recordedStages.append(loaded) }\n', '')
    old_loop = between(previous, '                    for index in [0, 1] {', '                    try prepared.source.prepared.checkpoint.checkUnchanged(); try check()')
    old_loop = old_loop.replace('                        func checked() throws { try check(); try gate.observe(); try check() }\n', '')
    require(loop == old_loop, 'ordered stage materializer loop changed beyond conditional retention')
    for token in ['case .loadOnly: comparison = nil', 'case .compare(let baseline):\n                        try checked()',
                  'stages: recordedStages, plan: plan, check: checked)',
                  'try QwenDenseShortParityBinding.requireBaseline(baseline, admission: admission)',
                  'operation: .loadOnly, check: check).load', 'guard retired0 == nil, retired1 == nil']:
        require(token in pair, 'pair closed comparison/retirement absent: ' + token)
    require(pair.index('compareQwenLayerStageRecordedRequest(baseline:') < pair.index('let observations = try gate.finish()'), 'pair gate finished before comparison')

    support = files['QwenDenseShortPairLoadSupport.swift']
    previous = originals['QwenDenseShortPairLoadSupport.swift']
    require(support.index('if let baseline { try QwenDenseShortParityBinding.requireBaseline') < support.index('QwenDenseStageLoadResources.requireInitial()') < support.index('MLX.withError'), 'pair baseline identity follows native or OS IO')
    require(support.count('VerifiedCheckpoint(directory:') == 1, 'pair checkpoint verification changed')
    require(between(support, '                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()', '                return QwenDenseShortPairReleased') ==
            between(previous, '                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()', '                return QwenDenseShortPairLoadReport'), 'pair release order changed')
    require(between(support, '            } catch {\n                let primary = error', '/// Existing loading-only entry;') ==
            previous[previous.index('            } catch {\n                let primary = error'):] + '\n', 'pair primary-error/cleanup changed')
    require('admission: admission, baseline: nil, check: check)' in support, 'old pair entry gained forward work')

    outer = files['QwenDenseShortParity.swift']
    ordered = ['recordQwenDenseShortBaseline(directory:', 'QwenDenseShortParityBinding.requireBaseline(',
               'try onBaseline(baseline)', 'compareQwenDenseShortPair(directory:', 'return .init(']
    require([outer.index(x) for x in ordered] == sorted(outer.index(x) for x in ordered), 'full record/release/publication/pair order changed')
    binding = files['QwenDenseShortParityBinding.swift']
    for token in ['canonicalJSONData(baseline.request) == canonicalJSONData(admission.request)',
                  'source.artifactAggregateSHA256 == spec.artifactSHA256',
                  'source.sourceConfigurationSHA256 == spec.configurationSHA256',
                  'source.planSHA256 == admission.metadata.plan.fingerprint',
                  'source.sourceModelTensorBytes == spec.sourceBytes',
                  'baseline.frames.map(\\.committedTokens) == [2, 3, 4]',
                  'rebuilt.fingerprint == baseline.fingerprint']:
        require(token in binding, 'selected baseline binding absent: ' + token)
    runtime = '\n'.join(re.sub(r'//[^\n]*', '', value) for name, value in files.items() if name != 'Main.swift')
    for pattern in [r'Memory\.(memoryLimit|cacheLimit)\s*=', r'\bunsafeBitCast\b', r'\bloadModel\s*\(', r'\bProcess\s*\(']:
        require(re.search(pattern, runtime) is None, 'excluded runtime expansion: ' + pattern)
    require(runtime.count('eval(') == 1, 'new eval beyond extracted actual baseline embedding')
    output = files['QwenDenseShortParityOutput.swift']
    require('''            try check()
            guard state == .writing else { throw ProbeError("Short parity publication was reentered") }
            try write(bytes); try check()''' in output, 'poisoned publisher can write after reentrant check')
    require(output.count('guard state == .writing') == 2, 'pre/post write state checks changed')

def run():
    files = {f.name:f.read_text() for f in (D/'proposed').glob('*.swift')}
    originals = {f.name:f.read_text() for f in (D/'originals').glob('*.swift')}
    validate(files, originals)
    mutations = [
        ('QwenVerifiedBaselineFinishing.swift', 'eval(activation)', 'eval(model)'),
        ('QwenDenseShortReferenceLoading.swift', 'observations.count < 8192', 'observations.count < 16384'),
        ('QwenDenseShortReferenceLoading.swift', 'case .loadOnly: baseline = nil', 'case .loadOnly: baseline = try recordQwenLayerStageBaseline()'),
        ('QwenDenseShortReferenceLoading.swift', 'guard retiredFiles == nil', 'guard true'),
        ('QwenDenseShortPairLoading.swift', 'return try withExtendedLifetime(values)', 'return try autoreleasepool'),
        ('QwenDenseShortPairLoading.swift', 'case .compare(let baseline):\n                        try checked()', 'case .compare(let baseline):'),
        ('QwenDenseShortPairLoadSupport.swift', 'if let baseline { try QwenDenseShortParityBinding.requireBaseline(baseline, admission: admission) }', ''),
        ('QwenDenseShortParityBinding.swift', 'source.sourceModelTensorBytes == spec.sourceBytes', 'source.sourceModelTensorBytes > 0'),
        ('QwenDenseShortParityBinding.swift', 'canonicalJSONData(baseline.request) == canonicalJSONData(admission.request)', 'true'),
        ('QwenDenseShortParity.swift', 'try onBaseline(baseline)', 'try check()'),
        ('QwenDenseShortParityOutput.swift', '            guard state == .writing else { throw ProbeError("Short parity publication was reentered") }\n            try write(bytes); try check()', '            try write(bytes); try check()'),
    ]
    rejects = []
    for name, old, new in mutations:
        require(old in files[name], 'mutation target absent')
        changed = dict(files); changed[name] = files[name].replace(old, new, 1)
        try:
            validate(changed, originals)
        except (ValueError, AssertionError):
            rejects.append(name + ': ' + old)
        else:
            raise AssertionError('source mutation was accepted')
    records = json.loads((D/'source-dependencies.json').read_text())['sources']
    for record in records:
        raw = Path(record['path']).read_bytes()
        require(len(raw) == record['bytes'] and hashlib.sha256(raw).hexdigest() == record['sha256'], 'dependency changed: ' + record['path'])
    fixture = json.loads((D/'entry-fixture-source-list-v3.json').read_text())
    for record in fixture['sources'] + [fixture['stdin']]:
        raw = Path(record['path']).read_bytes()
        require(len(raw) == record['bytes'] and hashlib.sha256(raw).hexdigest() == record['sha256'], 'final pure fixture input changed: ' + record['path'])
    stage = next(Path(x['path']).read_text() for x in records if x['path'].endswith('/VerifiedQwenLayerStageLoading.swift'))
    require('eval(model)' not in re.sub(r'//[^\n]*', '', stage), 'stage materializer now evaluates inert placeholders')
    for name, text in originals.items():
        path = Path(records[0]['path']).parent / name
        require(path.read_text() == text, 'original integration base changed: ' + name)
    patch = ''; stem = 'experiments/cluster/inference/Sources/ClusterInference/'
    for name, text in sorted(files.items()):
        patch += ''.join(difflib.unified_diff(originals.get(name, '').splitlines(True), text.splitlines(True),
            fromfile='a/'+stem+name if name in originals else '/dev/null', tofile='b/'+stem+name))
    require(patch == (D/'runtime.patch').read_text(), 'runtime patch differs from exact proposed files')
    return dict(kind='registered_dense_short_parity_source_checks', schema_version=1, passed=True,
        proposed_files=len(files), original_files=len(originals), unchanged_dependency_pins=len(records),
        root_pure_fixture_source_pins=len(fixture['sources']), root_pure_fixture_cases=dict(accepted=19, rejected=83),
        source_mutations_rejected=rejects, exact_legacy_finishing_extraction=True,
        existing_recorder_comparator_and_resource_policies_unchanged=True,
        swift_compiler_native_model_candidate_or_ssh_access=False,
        runtime_or_private_ownership_execution_test=False,
        proposed_sha256={name:hashlib.sha256(text.encode()).hexdigest() for name,text in sorted(files.items())})

if __name__ == '__main__':
    print(json.dumps(run(), indent=2, sort_keys=True))
