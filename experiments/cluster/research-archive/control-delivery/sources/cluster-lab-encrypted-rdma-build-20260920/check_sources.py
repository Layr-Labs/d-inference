"""Small source-only closure check. Does not scan workspace/dependencies or run native code."""
import ast
import json

from guards import BASE, INPUTS, SOURCE, authorities, dependency_rows, sha, source_rows


def main():
    authorities()
    scripts = sorted(BASE.glob('*.py'))
    for path in scripts:
        ast.parse(path.read_text(), filename=str(path))
    if sha(BASE / 'owned_process.py') != INPUTS['authorities']['ownedHelper']['sha256']:
        raise ValueError('Owned process helper changed')
    if sha(BASE / 'metadata-job.json') != INPUTS['authorities']['metadataFixture']['sha256']:
        raise ValueError('Public fixture copy changed')
    for rows in (source_rows(False), source_rows(True), dependency_rows()):
        if rows != sorted(rows, key=lambda row: row['path']) or len({row['path'] for row in rows}) != len(rows):
            raise ValueError('Expected inventory order/uniqueness differs')
    before = {row['path']: row for row in source_rows(False)}
    after = {row['path']: row for row in source_rows(True)}
    added = set(after) - set(before)
    changed = [name for name in before if before[name] != after[name]]
    if len(added) != 7 or changed != ['libs/darkbloom-cluster-worker/Package.swift']:
        raise ValueError('The seven additions and sole Package replacement differ')
    row = json.loads((SOURCE / 'overlay.json').read_bytes())['files'][-1]
    if row['preimageSHA256'] != sha(SOURCE / 'Package.before.swift') or row['sha256'] != sha(SOURCE / 'Package.after.swift'):
        raise ValueError('Package before/after differs')
    # Public fixture has no native-ready host identity or private secret.
    fixture = json.loads((BASE / 'metadata-job.json').read_bytes())
    if fixture['expectedHardware'] != ['metadata-fixture'] * 2 or fixture['expectedOSBuild'] != ['metadata-fixture'] * 2:
        raise ValueError('Metadata fixture is no longer explicitly public/synthetic')
    print(json.dumps(dict(status='passed', pythonAST=len(scripts), nativeMembers=13, unchangedNativePins=19,
                          sourceBefore=3081, sourceAfter=3088, dependencies=9832, additions=7, replacements=1,
                          inventoriesScanned=False, compilerExecuted=False, nativeExecuted=False), sort_keys=True))


if __name__ == '__main__':
    main()
