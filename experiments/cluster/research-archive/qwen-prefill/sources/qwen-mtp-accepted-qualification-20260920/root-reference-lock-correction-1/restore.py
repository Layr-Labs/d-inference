"""Restore only clean, owned dependency checkouts to their already-pinned revisions."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
sys.path.insert(0, str(ROOT / 'Build'))
import inputs
from owned_process import invoke_controller


def main():
    out = BASE / 'restoration-2'
    out.mkdir(mode=0o700)
    record = dict(status='started', steps=[], compilerExecuted=False, nativeExecuted=False)
    def save():
        (out / 'receipt.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    def run(name, argv):
        row = dict(name=name, argv=argv)
        record['steps'].append(row)
        try:
            with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
                invoke_controller(argv, stdout, stderr, row, timeout=30)
        finally:
            save()
        if row.get('exitCode') != 0 or not row.get('reaped') or not row.get('groupAbsent') or row.get('failure'):
            raise ValueError('Owned recovery command failed: ' + name)
        return (out / (name + '.stdout')).read_text().strip()
    try:
        inputs.authorities()
        ref = inputs.WORK / inputs.INPUTS['referenceResolved']['path']
        if inputs.sha(ref) != inputs.INPUTS['referenceResolved']['beforeSHA256']:
            raise ValueError('Failed reference lockfile no longer matches')
        current = inputs.inventory(inputs.WORK)
        expected = inputs.expected_sources()
        changed = [r['path'] for r, e in zip(current, expected) if r != e]
        if len(current) != len(expected) or changed != [inputs.INPUTS['referenceResolved']['path']]:
            raise ValueError('Only the reviewed reference lockfile delta is permitted')
        inputs.write_json(out / 'sources-before.json', dict(members=current))
        inputs.write_json(out / 'dependencies-before.json', dict(members=inputs.inventory(inputs.SCRATCH / 'checkouts')))
        worker = json.loads((inputs.WORK / 'libs/darkbloom-cluster-worker/Package.resolved').read_bytes())
        moves = []
        for pin in worker['pins']:
            name = pin['identity']
            path = inputs.SCRATCH / 'checkouts' / name
            if path.is_symlink() or not path.is_dir():
                raise ValueError('Owned checkout missing or symlinked')
            git = ['git', '-C', str(path)]
            dirty = run(name + '-clean', git + ['status', '--porcelain'])
            before = run(name + '-head', git + ['rev-parse', 'HEAD'])
            wanted = pin['state']['revision']
            if dirty:
                # The retained first attempt changed this exact index/tree before its read-only reflog refused HEAD update.
                if name != 'async-http-client' or run(name + '-worktree-diff', git + ['diff', '--name-only']) or run(name + '-index-tree', git + ['write-tree']) != run(name + '-wanted-tree', git + ['rev-parse', wanted + '^{tree}']):
                    raise ValueError('Only the exact owned partial checkout may be resumed')
            if run(name + '-object', git + ['rev-parse', '--verify', wanted + '^{commit}']) != wanted:
                raise ValueError('Pinned commit not present locally')
            if before != wanted:
                moves.append(dict(identity=name, before=before, after=wanted, git=git))
        if len(moves) != 23:
            raise ValueError('Unexpected dependency drift count')
        record['revisions'] = [{k:v for k,v in row.items() if k != 'git'} for row in moves]; save()
        release = inputs.SCRATCH / 'arm64-apple-macosx/release'
        for product in ['darkbloom-cluster-worker', 'cluster-inference']:
            run('preserve-' + product, ['/bin/cp', '-c', str(release / product), str(out / product)])
            if inputs.sha(release / product) != inputs.sha(out / product):
                raise ValueError('Preserved build product differs')
        for row in moves:
            # A retained ref preserves the rejected compilation's exact old commit.
            retained = inputs.SCRATCH / 'checkouts' / row['identity'] / '.git/refs/darkbloom/rejected-reference-20260920'
            if retained.exists():
                if retained.read_text().strip() != row['before']:
                    raise ValueError('Retained rejected revision differs')
            else:
                run(row['identity'] + '-retain', row['git'] + ['update-ref', 'refs/darkbloom/rejected-reference-20260920', row['before'], '0'*40])
            reflog = inputs.SCRATCH / 'checkouts' / row['identity'] / '.git/logs/HEAD'
            info = reflog.lstat()
            if reflog.is_symlink() or info.st_uid != os.geteuid():
                raise ValueError('Owned checkout reflog identity differs')
            record.setdefault('reflogModes', []).append(dict(path=str(reflog), before=info.st_mode & 0o777))
            reflog.chmod((info.st_mode & 0o777) | 0o200)
            run(row['identity'] + '-restore', row['git'] + ['checkout', '--detach', row['after']])
        tmp = ref.with_name('Package.resolved.same-revisions-new')
        with tmp.open('xb') as f:
            f.write((ROOT / 'Build/reference-Package.resolved').read_bytes()); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, ref)
        record['after'] = inputs.verify_final()
        inputs.write_json(out / 'sources-after.json', dict(members=inputs.inventory(inputs.WORK)))
        inputs.write_json(out / 'dependencies-after.json', dict(members=inputs.inventory(inputs.SCRATCH / 'checkouts')))
        record.update(status='passed', sourceAfterSHA256=inputs.sha(out / 'sources-after.json'),
                      dependencyAfterSHA256=inputs.sha(out / 'dependencies-after.json'))
    except BaseException as error:
        record.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        save()
    print(json.dumps(dict(status=record['status'], restoredRevisions=len(record['revisions']), after=record['after'])))


if __name__ == '__main__':
    main()
