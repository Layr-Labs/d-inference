"""Small source/inverse validation; optional root-only exact payload hashing after bind."""
from pathlib import Path
import argparse,ast,base64,hashlib,json,re
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent
OLD=ROOT/'qwen27b-8k-lookahead-owner-qualification-20260915'
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        while b:=f.read(1024*1024):h.update(b)
    return h.hexdigest()
def main():
    ap=argparse.ArgumentParser(allow_abbrev=False);ap.add_argument('--artifacts',action='store_true');a=ap.parse_args()
    m=json.loads((BASE/'manifest.json').read_bytes())
    for row in m['members']:
        p=BASE/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
        if p.suffix=='.py':ast.parse(p.read_text())
    control=(BASE/'Controller/Controller.swift').read_text();old=(ROOT/'cluster-owner-diagnostic-drain-draft-20260915/proposed/Entries/controller/Controller.swift').read_text()
    assert control.count('// PHASE OBSERVATION BEGIN')==6
    assert re.sub(r'^ *// PHASE OBSERVATION BEGIN\n.*?^ *// PHASE OBSERVATION END\n','',control,flags=re.M|re.S)==old
    for p in (BASE/'templates').rglob('*.py'):
        rel=p.relative_to(BASE/'templates')
        source=ROOT/'qwen27b-8k-lookahead-collection-20260915/read_sidecar_remote.py' if str(rel)=='read_sidecar_remote.py' else OLD/rel
        assert p.read_bytes()==source.read_bytes()
    for label,origin in [('comparison',OLD/'comparison'),('comparison-serial',ROOT/'qwen27b-cut16-numerical-audit-20260915')]:
        for file in (BASE/label).iterdir():
            assert file.is_file() and file.read_bytes()==(origin/file.name).read_bytes()
    assert (BASE/'validate_phase.py').read_bytes()==(ROOT/'resident-generation-phase-native-draft-20260916/validate_phase.py').read_bytes()
    for source in json.loads((BASE/'inputs/capacity-runtime-pins.json').read_bytes()):
        p=Path(source['path']);assert p.stat().st_size==source['bytes'] and sha(p)==source['sha256']
    runs=[]
    if (BASE/'bound-runs.json').exists():
        for item in json.loads((BASE/'bound-runs.json').read_bytes())['runs']:
            folder=Path(item['path']);assert folder.parent==BASE and sha(folder/'manifest.json')==item['manifestSHA256']
            for name,row in json.loads((folder/'manifest.json').read_bytes())['files'].items():
                p=folder/name;assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
            binding=json.loads((folder/'binding.json').read_bytes())
            control=binding['nativeArgumentControls'];path=Path(control['path'])
            assert path.stat().st_size==control['bytes'] and sha(path)==control['sha256'] and json.loads(path.read_bytes())['passed']
            config=json.loads((folder/'configuration/controller.json').read_bytes());cap=json.loads((folder/'capacity.json').read_bytes())
            assert config['requestSeconds']==120 and config['lifetimeSeconds']==300 and config['startupSeconds']==90
            assert config['promptTokenIDs']==json.loads((BASE/'inputs/prompt.ids.json').read_bytes()) and config['expectedTokenIDs']==json.loads((BASE/'inputs/expected-token-ids.json').read_bytes())
            assert config['chunkSize']==512 and config['outputCount']==128 and config['stopTokenIDs']==[] and config['cpuQualification'] is False
            for rank in [0,1]:
                p=folder/f'configuration/owner-rank{rank}.json';raw=p.read_bytes();assert raw.count(b'\n')==1 and raw.endswith(b'\n')
                own=json.loads(raw);t=base64.b64decode(own['readyTemplateBase64'],validate=True);assert t.count(b'\n')==1 and t.endswith(b'\n')
                ready=json.loads(t)['ready'];assert ready['requestCapacityBytes']==cap['ranks'][rank]['totalReservedBytes'] and ready['rank']==rank
                assert [x['buildSHA256'] for x in ready['identity']['peers']]==['649544175053810f804a662232bdfce43d5321b8fda0b3618959d94f1ad60182']*2
                assert own['leaseDirectory']=='/Users/developer/.darkbloom/cluster-device' and own['maximumLifetimeSeconds']==300 and own['stageCut']==16
            if a.artifacts:
                for rank in json.loads((folder/'deployment.json').read_bytes())['ranks']:
                    for row in rank['files']:
                        p=Path(row['source']);assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
            runs.append(item['policy'])
    if a.artifacts:assert len(runs)==2
    print(json.dumps(dict(sourceMembers=len(m['members']),controllerInverseBlocks=6,byteExactValidator=True,boundPolicies=runs,artifactsHashed=a.artifacts,modelOrRemoteExecuted=False)))
if __name__=='__main__':main()
