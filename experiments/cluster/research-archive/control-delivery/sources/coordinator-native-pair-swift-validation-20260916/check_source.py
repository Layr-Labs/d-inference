"""Small source/response-parser controls only: no inventory, copy, or child."""
import ast
from pathlib import Path
from inputs import BASE, B_OVERLAY, NATIVE_PAIR_METHODS, SWIFT_FILTER
from swift_results import MEMBER_METHODS, validate_swift_results


def main():
    for p in BASE.glob('*.py'):
        ast.parse(p.read_text(), filename=str(p))
    old = ast.parse((BASE / 'originals/inputs.py').read_text())
    original_filter = next(ast.literal_eval(n.value) for n in old.body if isinstance(n, ast.Assign)
                           and any(isinstance(t, ast.Name) and t.id == 'SWIFT_FILTER' for t in n.targets))
    if SWIFT_FILTER != original_filter + '|NativePairMessageTests':
        raise ValueError('Existing Swift filter changed')
    source = (B_OVERLAY / 'proposed/provider-swift/Tests/ProviderCoreTests/Protocol/NativePairMessageTests.swift').read_text()
    if source.count('@Test func ') != 2 or any('@Test func ' + name + '(' not in source for name in NATIVE_PAIR_METHODS):
        raise ValueError('Native Pair fixture closure changed')
    # Representative Swift Testing output. Success words in discovery/start
    # lines cannot substitute for completion, nor can one B pass count twice.
    base = ['✔ Test ' + name + '() passed after 0.001 seconds.' for name in MEMBER_METHODS + NATIVE_PAIR_METHODS]
    base += ['✔ Test "Real WebSocket requires explicit member acknowledgment" passed after 0.010 seconds.',
             '✔ Test run with 20 tests in 4 suites passed after 0.050 seconds.']
    text = '\n'.join(base)
    assert validate_swift_results(text)['nativePairMethodsPassed'] == 2
    one = '✔ Test ' + NATIVE_PAIR_METHODS[0] + '() passed after 0.001 seconds.'
    malformed = (
        text.replace(one, '◇ Test ' + NATIVE_PAIR_METHODS[0] + '() started.'),
        text + '\n' + one,
        text.replace('20 tests in 4 suites passed', '20 tests in 4 suites failed'),
        text.replace(base[-2], '◇ Test realSocketRoleNegotiation(acknowledge:) started.'),
    )
    for value in malformed:
        try:
            validate_swift_results(value)
        except ValueError:
            pass
        else:
            raise ValueError('Incomplete/ambiguous Swift result accepted')
    print('PASS: Python AST, exact filter extension, two fixture methods, complete/started/duplicate/failure/socket controls')


if __name__ == '__main__':
    main()
