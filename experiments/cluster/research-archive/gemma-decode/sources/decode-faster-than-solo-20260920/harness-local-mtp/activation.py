"""Late-bind actual compiled bytes and source composition; never builds."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): h.update(block)
    return h.hexdigest()


def bind(binary, build_path, sources_path):
    assert all(p.is_absolute() for p in (binary,build_path,sources_path)) and binary.name == 'GemmaResidentBenchmark'
    assert all(p.is_file() and not p.is_symlink() for p in (binary, build_path, sources_path))
    required = json.loads((ROOT/'required-native-sources.json').read_bytes())
    assert str(build_path)==required['actualBuildReceipt']['path'] and sha(build_path)==required['actualBuildReceipt']['sha256']
    assert str(sources_path)==required['actualSources']['path'] and sha(sources_path)==required['actualSources']['sha256']
    build = json.loads(build_path.read_bytes())
    assert build['exitCode'] == 0 and build['compilerReaped'] is True and build['groupAbsent'] is True
    assert build['gpuExecuted'] is False
    assert sha(binary) == build['nativeSHA256'] and binary.stat().st_size == build['nativeBytes']
    assert sha(sources_path) == build['sourcesSHA256']
    assert (build['nativeSHA256'],build['nativeBytes'])==(required['nativeSHA256'],required['nativeBytes'])
    for row in required['resources']:
        path=binary.parent/row['path'].removeprefix('bundle/')
        assert path.is_file() and not path.is_symlink() and path.stat().st_size==row['bytes'] and sha(path)==row['sha256']
    source = json.loads(sources_path.read_bytes())
    files = {x['path']: x for x in source['files']}
    assert len(files) == len(source['files'])
    required = json.loads((ROOT/'required-native-sources.json').read_bytes())
    for row in required['requiredFiles']: assert files[row['path']] == row, row['path']
    value = dict(schema='gemma4_local_mtp_actual_activation_v1', binary=str(binary),
        nativeSHA256=build['nativeSHA256'], nativeBytes=build['nativeBytes'],
        buildReceipt=str(build_path), buildReceiptSHA256=sha(build_path),
        sourceReceipt=str(sources_path), sourcesSHA256=sha(sources_path),
        requiredSourceSHA256=sha(ROOT/'required-native-sources.json'),
        stateSourceManifestSHA256=required['stateManifestSHA256'],
        outerCheckSourceManifestSHA256=required['outerCheckManifestSHA256'],
        physicalExecuted=False, gemmaWeightsExecuted=False)
    with (ROOT/'activation.json').open('x') as stream:
        json.dump(value, stream, indent=2); stream.write('\n')
    return value


def recheck():
    value = json.loads((ROOT/'activation.json').read_bytes())
    assert sha(Path(value['buildReceipt'])) == value['buildReceiptSHA256']
    assert sha(Path(value['sourceReceipt'])) == value['sourcesSHA256']
    assert sha(ROOT/'required-native-sources.json') == value['requiredSourceSHA256']
    return value
