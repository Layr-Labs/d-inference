"""Stage selected source declarations only; never edits the frozen origin."""
import hashlib
import json
import re
from pathlib import Path

from source_closure import ROOT, OUT, code_only, index, closure

PROPOSED = OUT / 'proposed'
PACKAGE = PROPOSED / 'libs/darkbloom-cluster'
SOURCES = PACKAGE / 'Sources/DarkbloomClusterRuntime'


def exact_block(source, marker):
    start = source.index(marker)
    start = source.rfind('\n', 0, start) + 1
    clean = code_only(source)
    opened = clean.index('{', start)
    depth = 1
    end = opened + 1
    while depth:
        if clean[end] == '{': depth += 1
        elif clean[end] == '}': depth -= 1
        end += 1
    if end < len(source) and source[end] == '\n': end += 1
    return start, end, source[start:end]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def declaration_body(source, declaration):
    clean = code_only(source)
    start = declaration['start']
    if declaration['kind'] in ('let', 'var', 'typealias'):
        raise ValueError('Manual extraction required for non-block declaration')
    parens = brackets = 0
    opened = None
    for offset in range(start, declaration['end']):
        ch = clean[offset]
        if ch == '(': parens += 1
        elif ch == ')': parens -= 1
        elif ch == '[': brackets += 1
        elif ch == ']': brackets -= 1
        elif ch == '{' and parens == brackets == 0:
            opened = offset
            break
    if opened is None:
        raise ValueError('Declaration body missing: ' + declaration['name'])
    depth = 1
    end = opened + 1
    while depth:
        if clean[end] == '{': depth += 1
        elif clean[end] == '}': depth -= 1
        end += 1
    return source[start:end] + '\n'


def main():
    SOURCES.mkdir(parents=True, exist_ok=True)
    edits = {}
    split_records = []
    compatibility = PROPOSED / 'experiments/cluster/inference/SharedRuntimeCompatibility'
    compatibility.mkdir(parents=True, exist_ok=True)
    # These exact methods are unrelated convenience/legacy partition surfaces.
    # Their preserved bodies belong to experimental compatibility, not the
    # minimal stage kernel's type closure.
    splits = {
        'CBv2RequestGeometry.swift': [
            ('    init(loaded: LoadedModel, maximumTokens: Int) throws {', 'CBv2RequestGeometry+LoadedModel.swift', 'CBv2RequestGeometry')],
        'LocalCorrectnessStorage.swift': [
            ('    static func validate(storage: PartitionStorageCommitment,', 'LocalCorrectnessStorage+Partition.swift', 'LocalCorrectnessStorage'),
            ('    private static func add(_ total: inout Int, _ value: Int) throws {', 'LocalCorrectnessStorage+Partition.swift', 'LocalCorrectnessStorage')],
    }
    for name, parts in splits.items():
        original = (ROOT / name).read_text()
        ranges = [(*exact_block(original, marker), target, owner) for marker, target, owner in parts]
        core = original
        for start, end, _, _, _ in sorted(ranges, reverse=True):
            core = core[:start] + core[end:]
        edits[name] = core
        for target in sorted({x[3] for x in ranges}):
            chosen = [x for x in ranges if x[3] == target]
            value = 'import Foundation\n\nextension ' + chosen[0][4] + ' {\n'
            value += '\n'.join(x[2] for x in chosen) + '}\n'
            (compatibility / target).write_text(value)
        for start, end, body, target, owner in ranges:
            split_records.append({'source': str(ROOT/name), 'sourceSHA256': digest(original.encode()),
                                  'startLine': original.count('\n', 0, start) + 1,
                                  'bodySHA256': digest(body.encode()),
                                  'target': str((compatibility/target).relative_to(PROPOSED)),
                                  'ownerType': owner, 'behavior': 'Exact method body retained; extension envelope only.'})

    nodes, symbols, extensions = index(edits)
    seeds = ['QwenLayerStageSession', 'loadVerifiedQwenLayerStage', 'Collective',
             'QwenResidentJACCLConfiguration', 'QwenLayerStageResidentLifecycle',
             'QwenStageMemoryObservation', 'runQwenLongPrefillResidentSteps']
    selected = closure(nodes, symbols, extensions, seeds, {'Options', 'emitJSON'})
    by_file = {}
    for item in selected['declarations']:
        by_file.setdefault(item['path'], []).append(item)
    move_list = []
    for relative, declarations in sorted(by_file.items()):
        source = ROOT / relative
        original = source.read_text()
        effective = edits.get(source.name, original)
        imports = '\n'.join(re.findall(r'(?m)^import [^\n]+', effective)) + '\n\n'
        chosen = sorted(declarations, key=lambda d: d['start'])
        all_declarations = [d for d in nodes.values() if d['path'] == relative]
        if len(chosen) == len(all_declarations):
            body = effective
            kind = 'whole_file' if effective == original else 'split_member_methods'
        else:
            body = imports + '\n'.join(declaration_body(effective, d) for d in chosen)
            kind = 'extract_top_level_declarations'
        renamed = {'Options.swift': 'ClusterRuntimeError.swift',
                   'ModelLoading.swift': 'QwenModelConstruction.swift',
                   'ModelPartition.swift': 'ClusterModelMetadata.swift',
                   'QwenMoEPartition.swift': 'QwenConfigurationInteger.swift',
                   'QwenLayerStageComparison.swift': 'QwenStageMemoryObservation.swift'}
        target_relative = renamed.get(relative, relative)
        target = SOURCES / target_relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
        move_list.append({'source': str(source), 'sourceSHA256': digest(original.encode()),
                          'target': str(target.relative_to(PROPOSED)), 'targetSHA256': digest(body.encode()),
                          'operation': kind, 'selectedDeclarations': [d['name'] for d in chosen],
                          'sourceDeclarationLines': [d['line'] for d in chosen]})
    manifest = '''// swift-tools-version: 6.3
import PackageDescription

// Staged source proposal. Normal provider remains macOS 14; the future native
// JACCL worker must build all dependencies with explicit 26.2 Swift/C++ targets.
let package = Package(
    name: "DarkbloomCluster",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DarkbloomClusterRuntime", targets: ["DarkbloomClusterRuntime"])],
    dependencies: [
        .package(path: "../mlx-swift"),
        .package(path: "../mlx-swift-lm"),
    ],
    targets: [
        .target(name: "DarkbloomClusterRuntime", dependencies: [
            .product(name: "Cmlx", package: "mlx-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
    ])
'''
    (PACKAGE / 'Package.swift').write_text(manifest)
    report = {'schema': 'selected_runtime_move_proposal_v1', 'base': str(ROOT),
              'status': 'Source staging only; compiler closure and cross-module adapters not yet established.',
              'mainRepositoryModified': False, 'frozenSourceModified': False,
              'nativeBuildOrExecutionPerformed': False,
              'sourceCount': len(move_list), 'selectedDeclarationCount': len(selected['declarations']),
              'seeds': seeds, 'stoppedSymbols': selected['stoppedSymbols'],
              'moveList': move_list, 'splitMethods': split_records,
              'pending': ['Same-implementation experiment compatibility access',
                          'Thin public resident facade and product worker after move-list review',
                          'Generation overlay and root-approved payload-cache source revision',
                          'Root-owned compiler validation']}
    (OUT / 'move-list.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'sourceCount': len(move_list), 'declarations': len(selected['declarations']),
                      'stoppedSymbols': selected['stoppedSymbols'],
                      'wholeFiles': sum(x['operation']=='whole_file' for x in move_list)},indent=2))


if __name__ == '__main__':
    main()
