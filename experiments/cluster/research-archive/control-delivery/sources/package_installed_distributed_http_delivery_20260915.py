from pathlib import Path
import hashlib, json, os, shutil, subprocess, time

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
ROOT = REPO.parent / 'cluster-research'
OUT = ROOT / 'installed-distributed-http-delivery-product-bundle-20260915'
NATIVE = REPO / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release'
PROVIDER = ROOT / 'distributed-http-terminal-delivery-private-build-1/workspace/provider-swift/.build/arm64-apple-macosx/debug'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

assert digest(NATIVE / 'darkbloom-cluster-worker') == 'ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5'
assert digest(NATIVE / 'mlx.metallib') == '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
handoff = ROOT / 'distributed-http-terminal-delivery-tested-handoff'
assert digest(handoff / 'manifest.json') == 'c64f1b957d6973295cbbbef8fc67496ac80502abebf7796f9838d08262d47343'
for item in json.loads((handoff / 'manifest.json').read_text())['members']:
    assert digest(handoff / item['path']) == item['sha256']
for item in json.loads((handoff / 'promotion.json').read_text())['files']:
    assert digest(REPO / item['path']) == item['sha256']
promotion = ROOT / 'distributed-http-terminal-delivery-main-integration-20260915/promotion.json'
assert json.loads(promotion.read_text())['all21PromotedExact'] is True
tests = ROOT / 'distributed-http-terminal-delivery-private-build-1/provider-tests-3/execution.json'
assert digest(tests) == '4168e0a6259b476658967f0d17af69a6991440f0aafb8eb30054006135deb188'
test_receipt = json.loads(tests.read_text())
assert test_receipt['exitCode'] == 0 and test_receipt['candidateSourceUnchanged'] is True
assert test_receipt['mainSourceUnchanged'] is True and test_receipt['timedOut'] is False
artifacts = json.loads((handoff / 'artifacts.json').read_text())
provider_artifact = next(x for x in artifacts['artifacts'] if x['role'] == 'provider')
assert str(PROVIDER / 'darkbloom') == provider_artifact['path']
assert provider_artifact['sha256'] == 'c4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350'
assert digest(PROVIDER / 'darkbloom') == provider_artifact['sha256']
OUT.mkdir(mode=0o700)
sources = [(PROVIDER / 'darkbloom', Path('darkbloom')),
           (NATIVE / 'darkbloom-cluster-worker', Path('darkbloom-cluster-worker')),
           (NATIVE / 'mlx.metallib', Path('mlx.metallib'))]
for bundle in sorted(PROVIDER.glob('*.bundle')):
    sources.extend((path, path.relative_to(PROVIDER)) for path in sorted(bundle.rglob('*')) if path.is_file())
files = []
for source, relative in sources:
    assert source.is_file() and not source.is_symlink(), source
    target = OUT / relative
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    executable = relative.as_posix() in ['darkbloom', 'darkbloom-cluster-worker']
    target.chmod(0o700 if executable else 0o600)
    assert digest(target) == digest(source)
    files.append({'path': relative.as_posix(), 'sha256': digest(target),
                  'bytes': target.stat().st_size, 'executable': executable})
assert next(x['sha256'] for x in files if x['path'] == 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal') == '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'
metadata = ROOT / 'cluster-prefill-selection-main-integration-20260915/native-metadata-1/capability.json'
assert digest(metadata) == '7e8a1480f1c8831cf447fa2f51935bf5e3b79024b1b83c09aa2df0bb6df883e7'
shutil.copyfile(metadata, OUT / 'capability.json')
(OUT / 'capability.json').chmod(0o600)
files.append({'path': 'capability.json', 'sha256': digest(metadata), 'bytes': metadata.stat().st_size, 'executable': False})
receipt = {'schema': 'installed_distributed_development_bundle_v1', 'files': files,
           'providerBuildConfiguration': 'debug', 'nativeBuildConfiguration': 'release',
           'providerTestReceiptSHA256': digest(tests), 'handoffManifestSHA256': digest(handoff / 'manifest.json'),
           'mainPromotionReceiptSHA256': digest(promotion), 'physicalProductQualification': False,
           'releaseQualification': False}
(OUT / 'bundle.json').write_text(json.dumps(receipt, indent=2) + '\n')
(OUT / 'bundle.json').chmod(0o600)
for arguments, label in [(['--help'], 'root-help'), (['start', '--help'], 'start-help'),
                         (['cluster', 'worker-owner', '--help'], 'owner-help'),
                         (['cluster', 'status', '--help'], 'status-help'),
                         (['cluster', 'doctor', '--help'], 'doctor-help')]:
    result = subprocess.run([str(OUT / 'darkbloom')] + arguments, capture_output=True, timeout=15)
    (OUT / (label + '.stdout')).write_bytes(result.stdout)
    (OUT / (label + '.stderr')).write_bytes(result.stderr)
    assert result.returncode == 0, (label, result.returncode)
print(json.dumps({'bundle': str(OUT), 'providerSHA256': digest(OUT / 'darkbloom'),
                  'nativeSHA256': digest(OUT / 'darkbloom-cluster-worker'),
                  'files': len(files), 'totalBytes': sum(x['bytes'] for x in files),
                  'metadataAndHelpOnly': True}))
