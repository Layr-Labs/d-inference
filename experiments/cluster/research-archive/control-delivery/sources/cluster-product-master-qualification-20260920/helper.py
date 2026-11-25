"""Rebuild the original CPU fixture against the exact current five module sources."""
from pathlib import Path
from common import BASE, WORKSPACE, read, require, save, sha
from check_process import run_owned


def build_helper(out):
    contract = read(BASE / 'helper-commands.json')
    steps = []
    for item in contract:
        argv = [arg.replace('{workspace}', str(WORKSPACE)).replace('{helper}', str(out)).replace('{fixtures}', str(BASE / 'Fixtures')) for arg in item['argv']]
        if item['name'] != 'compile-helper':
            module = WORKSPACE / 'libs/darkbloom-cluster/Sources' / item['name']
            listed = sorted(str(p) for p in module.glob('*.swift'))
            require(listed == sorted(arg for arg in argv if arg.startswith(str(module) + '/') and arg.endswith('.swift')), 'Helper module source membership changed')
        steps.append(dict(name=item['name'], execution=run_owned(argv, out, item['name'], 60), executionSHA256=sha(out / (item['name'] + '.json'))))
    names = ['native-member-fixture'] + ['lib' + item['name'] + '.dylib' for item in contract if item['name'] != 'compile-helper']
    artifacts = [dict(path=str(out / name), sha256=sha(out / name), bytes=(out / name).stat().st_size) for name in names]
    value = dict(passed=True, steps=steps, artifacts=artifacts, compilerExecuted=True, helperExecuted=False)
    save(out / 'checks.json', value)
    return dict(ownedCompilationSteps=len(steps), checksSHA256=sha(out / 'checks.json'))


def require_helper(out):
    value = read(out / 'checks.json')
    require(value['passed'] and len(value['steps']) == 6, 'Six completed helper builds required')
    for item in value['steps']:
        require(item['executionSHA256'] == sha(out / (item['name'] + '.json')), 'Helper command receipt changed')
        record = item['execution']
        require(record == read(out / (item['name'] + '.json')) and record['exitCode'] == 0 and record['reaped'] and record['groupAbsent'] and not record['timedOut'], 'Helper build did not naturally retire')
    for item in value['artifacts']:
        p = Path(item['path'])
        require(p.parent == out and p.is_file() and not p.is_symlink() and sha(p) == item['sha256'] and p.stat().st_size == item['bytes'], 'Matching rebuilt helper artifact required')
    return value
