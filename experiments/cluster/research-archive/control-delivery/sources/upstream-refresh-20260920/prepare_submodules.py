"""Preserve MAIN dependency edits while materializing current-master dependencies."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')
WORK = ROOT / 'workspace'
SPECS = [
    ('libs/mlx-swift', '0f4fe403bef6899e8a72882bc6d4036a7a62ae31'),
    ('libs/mlx-swift/Source/Cmlx/mlx', '3fa8f25e6451174d7b06be372c3a24272b77d88e'),
    ('libs/mlx-swift/Source/Cmlx/mlx-c', '02cf6f4d099023e4e0c0357248b8b3f83110e29d'),
    ('libs/mlx-swift-lm', 'e22fc82bdb7bfbd93874d56c7df9ca3306782b09'),
    ('libs/mlx', '3fa8f25e6451174d7b06be372c3a24272b77d88e'),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(path, *args):
    return subprocess.check_output(['/usr/bin/git', '-C', str(path), *args])


def prepare():
    stage = ROOT / 'submodule-source-overlays'
    stage.mkdir(mode=0o700)
    modules = []
    for rel, target in SPECS:
        source = MAIN / rel
        head = git(source, 'rev-parse', 'HEAD').decode().strip()
        assert git(source, 'cat-file', '-t', target).strip() == b'commit'
        rows = []
        for name in git(source, 'diff', '--name-only').decode().splitlines():
            path = source / name
            if path.is_dir():
                assert any(child == rel + '/' + name for child, _ in SPECS), name
                continue
            assert path.is_file() and not path.is_symlink(), path
            base = git(source, 'show', head + ':' + name)
            upstream = git(source, 'show', target + ':' + name)
            local = path.read_bytes()
            folder = stage / rel / name
            folder.mkdir(parents=True)
            for label, data in [('base', base), ('local', local), ('upstream', upstream)]:
                (folder / label).write_bytes(data)
            result = subprocess.run(['/usr/bin/git', 'merge-file', '-p', str(folder / 'local'),
                                     str(folder / 'base'), str(folder / 'upstream')], capture_output=True, timeout=10)
            assert result.returncode == 0 and not result.stderr, (rel, name, result.stderr)
            (folder / 'merged').write_bytes(result.stdout)
            rows.append(dict(path=name, originalSHA256=sha(base), localSHA256=sha(local),
                             upstreamSHA256=sha(upstream), mergedSHA256=sha(result.stdout),
                             mergedSource=str((folder / 'merged').relative_to(ROOT)), untracked=False))
        for name in git(source, 'ls-files', '--others', '--exclude-standard').decode().splitlines():
            path = source / name
            assert path.is_file() and not path.is_symlink(), path
            existing = subprocess.run(['/usr/bin/git', '-C', str(source), 'cat-file', '-e', target + ':' + name],
                                      capture_output=True, timeout=10)
            assert existing.returncode != 0, ('Upstream/untracked collision', rel, name)
            data = path.read_bytes()
            assert len(data) <= 1024 * 1024
            output = stage / rel / name / 'merged';output.parent.mkdir(parents=True)
            output.write_bytes(data)
            rows.append(dict(path=name, localSHA256=sha(data), upstreamSHA256=None,
                             mergedSHA256=sha(data), mergedSource=str(output.relative_to(ROOT)), untracked=True))
        modules.append(dict(path=rel, originalHead=head, targetHead=target, files=rows))
    receipt = dict(schema='upstream_dependency_preservation_v1',main=str(MAIN),workspace=str(WORK),modules=modules)
    with (ROOT / 'submodule-source-plan.json').open('x') as stream:json.dump(receipt,stream,indent=2)
    print(json.dumps(dict(prepared=True,modules=len(modules),overlays=sum(len(m['files']) for m in modules))))


def command(argv, log):
    start=time.monotonic()
    with log.open('xb') as stream:
        child=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        try:code=child.wait(timeout=120)
        except BaseException:
            os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=10);raise
    try:os.killpg(child.pid,0)
    except ProcessLookupError:pass
    else:raise AssertionError('Materialization process group remains')
    assert code==0,log
    return dict(argv=argv,exitCode=code,reaped=True,groupAbsent=True,elapsedSeconds=time.monotonic()-start,logSHA256=sha(log.read_bytes()))


def apply():
    plan_path=ROOT/'submodule-source-plan.json';plan=json.loads(plan_path.read_bytes())
    assert git(WORK,'rev-parse','HEAD').decode().strip()=='cc225365f866d9a0e6f565fe9426703785611f84'
    for module in plan['modules']:
        source=MAIN/module['path']
        assert git(source,'rev-parse','HEAD').decode().strip()==module['originalHead']
        for row in module['files']:
            assert sha((source/row['path']).read_bytes())==row['localSHA256']
            assert sha((ROOT/row['mergedSource']).read_bytes())==row['mergedSHA256']
    logs=ROOT/'submodule-materialization';logs.mkdir(mode=0o700)
    runs=[]
    for index,module in enumerate(plan['modules']):
        source=MAIN/module['path'];target=WORK/module['path']
        assert not target.exists() or (target.is_dir() and not any(target.iterdir())),target
        runs.append(command(['/usr/bin/git','clone','--shared','--no-checkout',str(source),str(target)],logs/f'{index}-clone.log'))
        runs.append(command(['/usr/bin/git','-C',str(target),'-c','advice.detachedHead=false','checkout','--detach',module['targetHead']],logs/f'{index}-checkout.log'))
        for row in module['files']:
            path=target/row['path']
            assert (sha(path.read_bytes()) if path.exists() else None)==row['upstreamSHA256'],path
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes((ROOT/row['mergedSource']).read_bytes())
            assert sha(path.read_bytes())==row['mergedSHA256']
        assert git(target,'rev-parse','HEAD').decode().strip()==module['targetHead']
    with (ROOT/'submodule-materialization.json').open('x') as stream:
        json.dump(dict(planSHA256=sha(plan_path.read_bytes()),commands=runs,compiled=False),stream,indent=2)
    print(json.dumps(dict(materialized=True,modules=len(plan['modules']),compiled=False)))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','apply'])
    args=parser.parse_args()
    prepare() if args.action=='prepare' else apply()
