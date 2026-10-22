from pathlib import Path
import hashlib, json, os, shutil, subprocess, time

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
ROOT = REPO.parent / 'cluster-research'
OUT = ROOT / 'installed-distributed-product-bundle-20260915'
NATIVE = REPO / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release'
PROVIDER = REPO / 'provider-swift/.build/arm64-apple-macosx/debug'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

assert digest(NATIVE / 'darkbloom-cluster-worker') == 'b8335e55de6e681e9b1b7be6ae6a64e57380cc20b3d6e6c13587517afee0a1d1'
assert digest(NATIVE / 'mlx.metallib') == '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
tests = ROOT / 'distributed-start-main-integration-20260915/provider-tests-2/execution.json'
assert json.loads(tests.read_text())['exitCode'] == 0
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
metadata = ROOT / 'installed-product-qualification-plan-20260915/capability.json'
assert digest(metadata) == '26fa98e8d1c59f83318f806c30b81381b868818a2cb9274f49150e4b5644577e'
shutil.copyfile(metadata, OUT / 'capability.json')
(OUT / 'capability.json').chmod(0o600)
files.append({'path': 'capability.json', 'sha256': digest(metadata), 'bytes': metadata.stat().st_size, 'executable': False})
receipt = {'schema': 'installed_distributed_development_bundle_v1', 'files': files,
           'providerBuildConfiguration': 'debug', 'nativeBuildConfiguration': 'release',
           'providerTestReceiptSHA256': digest(tests), 'physicalProductQualification': False,
           'releaseQualification': False}
(OUT / 'bundle.json').write_text(json.dumps(receipt, indent=2) + '\n')
(OUT / 'bundle.json').chmod(0o600)
for arguments, label in [(['--help'], 'root-help'), (['start', '--help'], 'start-help'),
                         (['cluster', 'worker-owner', '--help'], 'owner-help')]:
    result = subprocess.run([str(OUT / 'darkbloom')] + arguments, capture_output=True, timeout=15)
    (OUT / (label + '.stdout')).write_bytes(result.stdout)
    (OUT / (label + '.stderr')).write_bytes(result.stderr)
    assert result.returncode == 0, (label, result.returncode)
print(json.dumps({'bundle': str(OUT), 'providerSHA256': digest(OUT / 'darkbloom'),
                  'nativeSHA256': digest(OUT / 'darkbloom-cluster-worker'),
                  'files': len(files), 'totalBytes': sum(x['bytes'] for x in files),
                  'metadataAndHelpOnly': True}))
