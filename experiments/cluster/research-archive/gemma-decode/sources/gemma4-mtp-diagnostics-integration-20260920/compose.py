"""Exact memo109 + frozen tiny pull + corrected dense diagnostic composition.

Without --output, checks small sources only. Only root schedules --apply/build.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(row):
    path = Path(row['path'])
    assert path.is_absolute() and path.is_file() and not path.is_symlink(), path
    data = path.read_bytes()
    assert len(data) == row['bytes'] and sha(data) == row['sha256'], path
    return data


def local(row, directory):
    return read(dict(row, path=str(directory / row['path'])))


def manifest(row):
    value = json.loads(read(row))
    directory = Path(row['path']).parent
    for member in value['members']:
        local(member, directory)
    return value


def transformed(data, operations, reverse=False):
    text = data.decode()
    for op in reversed(operations) if reverse else operations:
        before, after = (op['after'], op['before']) if reverse else (op['before'], op['after'])
        assert text.count(before) == op['count'], before
        text = text.replace(before, after)
    return text.encode()


def prepare():
    own = ROOT / 'source-inputs.json'
    for member in json.loads(own.read_bytes())['members']:
        local(member, ROOT)
    spec = json.loads((ROOT / 'integration.json').read_bytes())
    for row in spec['manifests']:
        manifest(row)
    for row in spec['controls']:
        read(row)
    predecessor = json.loads(read(spec['predecessorSources']))
    base = json.loads(read(spec['baseSources']))
    old = {r['path']: r for r in predecessor['files']}
    files = {r['path']: r for r in base['files']}
    assert len(old) == len(predecessor['files']) == 108
    assert len(files) == len(base['files']) == 109
    assert base['baseSourceSHA256'] == spec['predecessorSources']['sha256']
    differences = [dict(path=p, before=old.get(p), after=files.get(p))
                   for p in sorted(old.keys() | files.keys()) if old.get(p) != files.get(p)]
    assert differences == spec['memoDifferences']
    entry = spec['entryProof']
    original, tiny, dense, combined = [read(entry[k]) for k in ['original', 'tiny', 'dense', 'combined']]
    assert transformed(original, entry['tinyOperations']) == tiny
    assert transformed(original, entry['denseOperations']) == dense
    assert transformed(tiny, entry['denseOperations']) == combined
    assert transformed(dense, entry['tinyOperations']) == combined
    assert transformed(transformed(combined, entry['tinyOperations'], True), entry['denseOperations'], True) == original
    assert transformed(transformed(combined, entry['denseOperations'], True), entry['tinyOperations'], True) == original
    work = Path(spec['workspace'])
    for item in spec['changes']:
        output = read(item['source'])
        if item.get('externalPreimage'):
            assert item['destination'] not in files
            assert read(item['externalPreimage']) == local(item['before'], work)
        else:
            assert files.get(item['destination']) == item['before']
        files[item['destination']] = dict(path=item['destination'], bytes=len(output), sha256=sha(output))
    expected = json.loads((ROOT / 'expected-sources.json').read_bytes())['files']
    assert [files[p] for p in sorted(files)] == expected and len(expected) == 116

    def check_preimages():
        for row in base['files']:
            local(row, work)
        for item in spec['changes']:
            read(item['source'])
            if item['before'] is None:
                assert not (work / item['destination']).exists(), item['destination']
            else:
                local(item['before'], work)

    return spec, predecessor, expected, check_preimages


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    assert not args.apply or args.output
    spec, predecessor, files, check = prepare()
    check()
    if args.output:
        out = args.output
        assert out.is_absolute() and out.parent.resolve() == out.parent
        out.mkdir(mode=0o700)
        work = Path(spec['workspace'])
        for item in spec['changes']:
            dest = out / 'sources' / item['destination']
            dest.parent.mkdir(parents=True, exist_ok=True)
            with dest.open('xb') as stream:
                stream.write(read(item['source']))
            if item['before']:
                saved = out / 'before' / item['destination']
                saved.parent.mkdir(parents=True, exist_ok=True)
                with saved.open('xb') as stream:
                    stream.write(local(item['before'], work))
        check()
        applied = []
        if args.apply:
            for item in spec['changes']:
                dest = work / item['destination']
                with dest.open('wb' if item['before'] else 'xb') as stream:
                    stream.write(read(item['source']))
                applied.append(item['destination'])
                (out / 'apply-progress.json').write_text(json.dumps(applied, indent=2) + '\n')
            for row in files:
                local(row, work)
        result = dict(predecessor, schema='gemma4_remote_mtp_composition_v1', files=files,
                      workspaceMutated=args.apply, qualifierPredecessor=spec['predecessorSources'],
                      memoPredecessor=spec['baseSources'],
                      qualifierSourceManifestSHA256=spec['qualifierManifestSHA256'],
                      denseSourceManifestSHA256=spec['denseManifestSHA256'],
                      denseHeadCorrectionManifestSHA256=spec['denseHeadManifestSHA256'],
                      diagnosticsSourceManifestSHA256=sha((ROOT / 'source-inputs.json').read_bytes()),
                      diagnosticsIntegrationSHA256=sha((ROOT / 'integration.json').read_bytes()),
                      diagnosticsChanges=spec['changes'])
        with (out / 'sources.json').open('x') as stream:
            json.dump(result, stream, indent=2)
            stream.write('\n')
    print(json.dumps(dict(status='applied' if args.apply else 'checked', sources=116,
                          changes=len(spec['changes']), workspaceMutated=args.apply,
                          compilerExecuted=False, nativeExecuted=False)))


if __name__ == '__main__':
    main()
