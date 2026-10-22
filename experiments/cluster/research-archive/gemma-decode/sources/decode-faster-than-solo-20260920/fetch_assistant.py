"""Fetch only the immutable, catalog-bound Gemma assistant; never execute it."""
from pathlib import Path
import hashlib
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parent / 'assistant-artifact'


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def main():
    started = time.monotonic()
    reference = json.loads((ROOT / 'reference.json').read_bytes())
    manifest = json.loads((ROOT / 'manifest.json').read_bytes())
    assert sha(ROOT / 'manifest.json') == reference['manifest_sha256']
    assert manifest['schema_version'] == 1
    assert manifest['r2_prefix'] == reference['r2_prefix']
    assert manifest['version'] == reference['revision']
    files = manifest['files']
    assert len(files) == manifest['file_count'] == reference['file_count'] == 2
    assert {v['path'] for v in files} == {'config.json', 'model.safetensors'}
    assert sum(v['size_bytes'] for v in files) == manifest['total_size_bytes'] == reference['total_size_bytes']
    receipt = dict(status='started', gpuExecuted=False, files=[])
    try:
        for row in sorted(files, key=lambda value: value['path']):
            name = row['path']
            assert row['role'] == ('config' if name == 'config.json' else 'weight')
            assert 0 < row['size_bytes'] <= 300_000_000
            destination = ROOT / name
            partial = ROOT / (name + '.partial')
            assert not destination.exists() and not partial.exists()
            url = 'https://models.darkbloom.ai/' + reference['r2_prefix'] + '/' + name
            process = subprocess.run([
                '/usr/bin/curl', '--fail', '--silent', '--show-error', '--proto', '=https',
                '--connect-timeout', '10', '--max-time', '180',
                '--max-filesize', str(row['size_bytes']), '--output', str(partial), url,
            ], stdin=subprocess.DEVNULL, capture_output=True, timeout=190)
            assert process.returncode == 0, process.stderr.decode()
            assert partial.is_file() and not partial.is_symlink()
            assert partial.stat().st_size == row['size_bytes'] and sha(partial) == row['sha256']
            partial.rename(destination)
            receipt['files'].append(row)
        digest = hashlib.sha256()
        for row in sorted(files, key=lambda value: value['path']):
            digest.update(bytes.fromhex(sha(ROOT / row['path'])))
        assert digest.hexdigest() == manifest['aggregate_sha256']
        assert sha(ROOT / 'config.json') == reference['config_sha256']
        receipt['aggregateSHA256'] = digest.hexdigest()
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt['status'] = 'failed'
        receipt['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        receipt['elapsedSeconds'] = time.monotonic() - started
        with (ROOT / 'download-receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2)
        print(json.dumps(receipt), flush=True)


if __name__ == '__main__':
    main()
