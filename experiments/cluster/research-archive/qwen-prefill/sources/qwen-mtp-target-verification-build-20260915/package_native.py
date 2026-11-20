"""Package the built qualification entry with existing pinned native resources."""
from pathlib import Path
import hashlib,json,subprocess
BASE=Path(__file__).resolve().parent

def pin(path):
    size=0;digest=hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda:stream.read(1024*1024),b''):size+=len(data);digest.update(data)
    return dict(bytes=size,sha256=digest.hexdigest())

def main():
    receipt=json.loads((BASE/'native-1/receipt.json').read_bytes())
    if receipt['status']!='passed':raise RuntimeError('Native build has not passed')
    old=BASE.parent/'qwen-resident-mtp-registered-probe-native-build-20260915/runtime-bundle'
    pairs=[('TargetVerificationCheck',BASE/'workspace/libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/TargetVerificationCheck',receipt['binarySHA256']),
           ('mlx.metallib',old/'mlx.metallib','2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'),
           ('mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal',old/'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal','4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149')]
    bundle=BASE/'native-bundle';bundle.mkdir(mode=0o700);files=[]
    for name,source,expected in pairs:
        before=pin(source)
        if before['sha256']!=expected:raise RuntimeError('Build/resource pin differs')
        dest=bundle/name;dest.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run(['/bin/cp','-c',str(source),str(dest)],check=True,timeout=30)
        if pin(dest)!=before or pin(source)!=before:raise RuntimeError('Copied resource differs')
        files.append(dict(path=name,**before))
    result=dict(schema='target_verification_native_check_bundle_v1',files=files,sourceSnapshotSHA256=receipt['sourceSnapshotSHA256'],dependencySnapshotSHA256=receipt['dependencySnapshotSHA256'],foundationGroupsPassed=11,nativeArgumentCheckPassed=True,nativeFixtureExecuted=False,modelExecution=False,bilateralVerification=False,runArguments=['run-native-state-on-gpu'],canonicalDeviceExclusion='~/.darkbloom/cluster-device',processAlarmSeconds=30)
    (bundle/'bundle.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n');print(pin(bundle/'bundle.json'))
if __name__=='__main__':main()
