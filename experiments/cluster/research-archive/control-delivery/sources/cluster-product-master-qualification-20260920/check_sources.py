"""Small source/metadata checks only. --current checks named final overlay paths."""
import argparse
import ast
from pathlib import Path
from common import BASE, inputs, read, require, sha, source_contract


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--current', action='store_true')
    args = parser.parse_args()
    context = inputs()
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    coverage = read(BASE / 'test-coverage.json')
    require(coverage['testCount'] == 192 and len(coverage['completionLabels']) == 192 and len(set(coverage['completionLabels'])) == 192, 'Default completion contract differs')
    require(coverage['completionLabels'] == sorted(coverage['completionLabels']) and len(coverage['parameterizedCaseStarts']) == 5, 'Completion grammar differs')
    require('NativeHardwareDriverTests' not in coverage['swiftFilter'], 'Private test filter leaked')
    for row in coverage['addedSourceLabels']:
        require(sum(label in coverage['completionLabels'] for label in row['labels']) == len(row['labels']), 'New exact labels omitted')
    require(sum(len(row['labels']) for row in coverage['addedSourceLabels']) == 11, 'Identity/initiation/type test delta differs')
    commands = read(BASE / 'helper-commands.json')
    require(len(commands) == 6 and commands[-1]['name'] == 'compile-helper', 'Actual CPU helper closure differs')
    require(all(row['timeoutSeconds'] == 60 and row['argv'][:4] == ['xcrun', 'swiftc', '-j', '2'] for row in commands), 'Helper bound differs')
    require(len(read(BASE / 'cache-dependencies.json')) == 9832, 'Prior actual locked cache inventory differs')
    if args.current:
        source_contract(Path(context['sourceWorkspace']), git_heads=True)
        for row in read(BASE / 'coordinator-context.json'):
            require(sha(Path(context['sourceWorkspace']) / row['path']) == row['sha256'], 'Coordinator composition differs')
    print('PASS: frozen source/AST, 192 exact labels, 6 helper steps, 9832 locked cache inputs; no preparation or execution')


if __name__ == '__main__':
    main()
