"""Read-only Swift declaration index; review aid, not a compiler dependency proof."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research/resident-jaccl-worker-build-20260915/workspace/experiments/cluster/inference/Sources/ClusterInference')
OUT = Path(__file__).resolve().parent


def code_only(source):
    # Keep offsets/newlines while excluding comments/string contents. Swift
    # interpolation references are intentionally a separately reviewed limit.
    value = list(source)
    i = 0
    while i < len(source):
        start = i
        if source.startswith('//', i):
            i = source.find('\n', i)
            if i < 0:
                i = len(source)
        elif source.startswith('/*', i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith('/*', i):
                    depth += 1; i += 2
                elif source.startswith('*/', i):
                    depth -= 1; i += 2
                else:
                    i += 1
        elif source[i] == '"':
            delimiter = '"""' if source.startswith('"""', i) else '"'
            i += len(delimiter)
            while i < len(source):
                if source[i] == '\\':
                    i += 2
                elif source.startswith(delimiter, i):
                    i += len(delimiter); break
                else:
                    i += 1
        else:
            i += 1
            continue
        for n in range(start, min(i, len(value))):
            if value[n] != '\n':
                value[n] = ' '
    return ''.join(value)


def index(overrides=None):
    nodes = {}
    by_symbol = {}
    extensions = {}
    pattern = re.compile(r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|package|final|indirect|nonisolated|@\w+)\s+)*(struct|class|enum|protocol|typealias|func|extension|let|var)\s+([A-Za-z_]\w*)')
    for path in sorted(ROOT.rglob('*.swift')):
        if path.name == 'Main.swift' or path.stem.endswith(('Check', 'Fixture')):
            continue
        raw = (overrides or {}).get(path.name, path.read_text())
        code = code_only(raw)
        depth = 0
        depths = []
        for ch in code:
            depths.append(depth)
            if ch == '{': depth += 1
            elif ch == '}': depth -= 1
        matches = [m for m in pattern.finditer(code) if depths[m.start()] == 0]
        for n, match in enumerate(matches):
            kind, name = match.groups()
            end = matches[n + 1].start() if n + 1 < len(matches) else len(raw)
            key = str(path.relative_to(ROOT)) + ':' + str(raw.count('\n', 0, match.start()) + 1)
            nodes[key] = {'path': str(path.relative_to(ROOT)), 'name': name, 'kind': kind,
                          'start': match.start(), 'end': end,
                          'line': raw.count('\n', 0, match.start()) + 1,
                          'tokens': set(re.findall(r'\b[A-Za-z_]\w*\b', code[match.start():end]))}
            if kind == 'extension':
                extensions.setdefault(name, set()).add(key)
            else:
                by_symbol.setdefault(name, set()).add(key)
    return nodes, by_symbol, extensions


def closure(nodes, by_symbol, extensions, seeds, stops):
    pending = [k for seed in seeds for k in by_symbol.get(seed, ())]
    found = set()
    references = {}
    stopped = {}
    while pending:
        key = pending.pop()
        if key in found:
            continue
        node = nodes[key]
        if node['name'] in stops:
            stopped.setdefault(node['name'], []).append(key)
            continue
        found.add(key)
        refs = set()
        for token in node['tokens']:
            refs.update(by_symbol.get(token, ()))
            refs.update(extensions.get(token, ()))
        refs.discard(key)
        references[key] = sorted(refs)
        pending.extend(refs - found)
    return {'seeds': seeds, 'stoppedSymbols': sorted(stopped),
            'files': sorted({nodes[k]['path'] for k in found}),
            'declarations': [{'key': k, **{p: v for p, v in nodes[k].items() if p != 'tokens'},
                              'references': references.get(k, [])} for k in sorted(found)]}


def main():
    nodes, symbols, extensions = index()
    common = ['QwenLayerStageSession', 'loadVerifiedQwenLayerStage', 'Collective', 'QwenResidentJACCLConfiguration']
    resident = ['runQwenLongPrefillResidentRankCohort', 'runQwenLongPrefillResidentSoloCohort']
    report = {'scope': 'Lexical declaration closure; no compiler, macro, overload or interpolation proof.',
              'root': str(ROOT), 'indexedDeclarations': len(nodes),
              'duplicateSymbols': {k: sorted(v) for k, v in symbols.items() if len(v) > 1},
              'kernel': closure(nodes, symbols, extensions, common, {'Options', 'log', 'emitJSON'}),
              'resident': closure(nodes, symbols, extensions, resident, {'Options', 'log', 'emitJSON'})}
    paths = sorted(set(report['kernel']['files']) | set(report['resident']['files']))
    report['sourcePins'] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
    destination = OUT / 'lexical-closure.json'
    destination.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: {'files': len(report[k]['files']), 'declarations': len(report[k]['declarations']),
                          'stoppedSymbols': report[k]['stoppedSymbols']} for k in ['kernel', 'resident']}, indent=2))
    print('duplicateSymbols:', json.dumps(report['duplicateSymbols']))


if __name__ == '__main__':
    main()
