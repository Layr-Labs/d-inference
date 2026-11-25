"""Bind the actual failed c43 candidate and preserve its unqualified binary."""
import argparse,json,re,os
from pathlib import Path
import sys
sys.path.insert(0, '/Users/developer/DarkbloomDev/cluster-research/cluster-native-numerical-provider-build-draft-20260917')
from context import BASE,ELIGIBILITY_SHA,PRIOR,NUMERICAL_SHA,WORKSPACE
from guards import verify,sha,save,require

def natural(step,code=0):
    require(step['exitCode']==code and step['reaped'] and step['groupAbsent']
        and not step.get('timedOut') and not step.get('killedOwnedGroup'),'Prior child did not naturally retire')

def bind(binary_sha):
    _,main,before,_=verify()
    require(re.fullmatch('[0-9a-f]{64}',binary_sha),'Root must supply actual current binary hash')
    require(json.loads((PRIOR/'candidate-before.json').read_text())==before
        and json.loads((PRIOR/'source-before.json').read_text())==main,'Actual failed source inventory differs')
    pins=[]
    def pin(path):
        require(path.is_file() and not path.is_symlink(),'Actual regular qualification evidence required')
        pins.append(dict(path=str(path),bytes=path.stat().st_size,sha256=sha(path)))
    for name in ['candidate-before.json','source-before.json','preparation.json']:pin(PRIOR/name)
    for phase in ['helper','tests']:
        directory=PRIOR/(phase+'-1');record=json.loads((directory/'checks.json').read_text())
        require(record['phase']==phase and record['manifestSHA256']==ELIGIBILITY_SHA
            and record['candidateSHA256']==sha(PRIOR/'candidate-before.json'),'Actual c43 phase identity differs')
        require(json.loads((directory/'source-recheck.json').read_text())['unchanged'] is True,'Prior source recheck failed')
        for path in sorted(directory.iterdir()):
            if path.is_file() and path.suffix in ['.json','.stdout','.stderr']:pin(path)
        if phase=='helper':
            require(record['passed'] is True and len(record['artifacts'])==6 and len(record['steps'])==17,'Actual c43 helper qualification incomplete')
            for step in record['steps']:natural(step)
            for row in record['artifacts']:
                path=Path(row['path']);require(path.parent==directory and sha(path)==row['sha256'],'Prior helper changed');pin(path)
        else:
            require(record['passed'] is False and record['executionSHA256']==sha(directory/'execution.json'),'Known failed test evidence differs')
            natural(json.loads((directory/'execution.json').read_text()),1)
            raw=(directory/'execution.stdout').read_text()+'\n'+(directory/'execution.stderr').read_text()
            failed=re.findall(r'(?m)^✘ Test (?!run with )(.+?) failed after \d+(?:\.\d+)? seconds with 1 issue\.$',raw)
            passed=re.findall(r'(?m)^✔ Test (.+?) passed after \d+(?:\.\d+)? seconds\.$',raw)
            wanted=json.loads((BASE/'discovered-coverage.json').read_text())['completionLabels']
            require(failed==['combinedMeshOwnerStillRefusesNativeReady()'] and sorted(passed+failed)==wanted
                and len(re.findall(r'(?m)^✘ Test run with 112 tests in 18 suites failed after \d+(?:\.\d+)? seconds with 1 issue\.$',raw))==1,
                'Exactly the retained112-method failure must be preserved, never accepted as a pass')
    binary=WORKSPACE/'provider-swift/.build/debug/darkbloom'
    require(binary.is_file() and not binary.is_symlink() and sha(binary)==binary_sha,'Current unqualified binary changed')
    return dict(schema='numerical_provider_activation_v1',wrapperManifestSHA256=sha(BASE/'manifest.json'),
        priorBinarySHA256=binary_sha,priorBinaryBytes=binary.stat().st_size,sourcePins=pins,
        numericalManifestSHA256=NUMERICAL_SHA,priorTestsPassed=False,priorBinaryQualified=False,
        materializationExecuted=False,compilerExecuted=False,tlsQualificationRequiredBeforePhysicalUse=True)

def require_activation():
    value=json.loads((BASE/'activation-1/activation.json').read_text())
    require(value['wrapperManifestSHA256']==sha(BASE/'manifest.json'),'Activation wrapper changed')
    for row in value['sourcePins']:
        path=Path(row['path']);require(path.is_file() and not path.is_symlink() and path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],'Bound prior evidence changed')
    return value

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--prior-binary-sha256',required=True);a=p.parse_args()
    value=bind(a.prior_binary_sha256);directory=BASE/'activation-1';directory.mkdir(mode=0o700)
    save(directory/'activation.json',value);print(json.dumps(dict(activationSHA256=sha(directory/'activation.json'))))

if __name__=='__main__':os.umask(0o077);main()
