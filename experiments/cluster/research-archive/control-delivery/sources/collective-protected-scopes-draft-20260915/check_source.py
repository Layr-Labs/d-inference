"""Source-only exact overlay/control validation; never imports MLX or builds."""
from pathlib import Path
import hashlib, json, subprocess, tempfile
BASE = Path(__file__).resolve().parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    data = json.loads((BASE/'integration.json').read_bytes())
    assert len(data['files']) == 14
    for row in data['files']:
        path = Path(row['path'])
        assert not path.is_absolute() and '..' not in path.parts
        assert sha(BASE/'proposed'/path) == row['afterSHA256']
        current = MAIN/path
        if row['beforeSHA256'] is None: assert not current.exists()
        else:
            assert sha(current) == row['beforeSHA256']
            assert sha(BASE/'originals'/path) == row['beforeSHA256']
    controls = json.loads((BASE/'controls.json').read_bytes())['files']
    for row in controls: assert sha(MAIN/row['path']) == row['sha256']
    with tempfile.TemporaryDirectory(prefix='protected-scopes-source-') as folder:
        root = Path(folder)
        for row in data['files']:
            if row['beforeSHA256'] is None: continue
            target=root/row['path'];target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes((BASE/'originals'/row['path']).read_bytes())
        result = subprocess.run(['/usr/bin/git','apply','--unsafe-paths',str(BASE/'runtime.patch')], cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
        assert result.returncode == 0, result.stderr.decode()
        for row in data['files']: assert sha(root/row['path']) == row['afterSHA256']
    runtime=BASE/'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    collective=(runtime/'Collective.swift').read_text()
    assert 'private final class CollectiveNativeEndpoint: CollectiveCiphertextEndpoint' in collective
    assert 'final class Collective: CollectiveCiphertextEndpoint' not in collective
    assert collective.index('try configuration.resourcePolicy.requireQualified()') < collective.index('let endpoint = try CollectiveNativeEndpoint')
    session=(runtime/'CollectiveProtectedSession.swift').read_text()
    assert session.count('records = try .init(') == 1
    generation=(runtime/'QwenLayerStageGenerationTransport.swift').read_text()
    assert 'collective.sendCompleted' not in generation and 'collective.receiveCompleted' not in generation
    assert 'fileprivate let consumedEndpoint: Collective' in generation
    assert 'receiveAckValues(endpoint: ticket.consumedEndpoint' in generation
    assert 'retiredEndpoint' in generation and 'collective.invalidateProtection()' in generation
    source=(runtime/'QwenResidentRuntime+Load.swift').read_text()
    assert 'loadNative(configuration, bootstrap: bootstrap, protection: nil)' in source
    assert source.index('try protection?.requireBinding') < source.index('QwenResidentProcessLease.shared.acquire()')
    print(json.dumps(dict(overlayFiles=len(data['files']), unchangedControls=len(controls), patchReplay=True,
        swiftCompiled=False, swiftTestsRun=False, nativeOrRemoteRun=False, sourceOnly=True),sort_keys=True))
if __name__=='__main__':main()
