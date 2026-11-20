#!/usr/bin/env python3
"""Source-only runner/list/prose checks; never invokes Swift or the runner."""
from pathlib import Path
import hashlib,json,re
D=Path(__file__).resolve().parent
R=Path('/Users/developer/DarkbloomDev/d-inference')
C=Path('/Users/developer/DarkbloomDev/cluster-research/registered-dense-constructor-probe-draft')
def sha(b): return hashlib.sha256(b).hexdigest()
def check(value,message):
    if not value: raise AssertionError(message)
manifest=(C/'manifest.json').read_bytes();check(sha(manifest)=='138f261fa56103ce12c8a75177c9292ca50e4fb20e3e061f85f6821a59514b55','native draft pin changed')
for item in json.loads(manifest)['members']:
    raw=(C/item['path']).read_bytes();check(sha(raw)==item['sha256'] and len(raw)==item['bytes'],'native member changed')
map_data=json.loads((D/'source-map.json').read_text());check(len(map_data['orderedCompilerInputs'])==15,'compiler input count')
source_list=json.loads((C/'fixture-source-list.json').read_text())
check([x['origin'] for x in map_data['orderedCompilerInputs']]==source_list['sources'],'ordered source list differs')
for item in map_data['orderedCompilerInputs']:
    p=item['origin'];raw=Path(p['path']).read_bytes();check(sha(raw)==p['sha256'] and len(raw)==p['bytes'],'source bytes differ')
    current=R/item['destination'];check(current.is_file() and sha(current.read_bytes())==p['sha256'],'integrated fixture/compiler source differs')
stdin=map_data['sharedStdin'];check(sha(Path(stdin['path']).read_bytes())==stdin['sha256'],'shared stdin differs')
runner=D/'proposed/experiments/cluster/inference/Tests/ConstructorProbes/run.sh';text=runner.read_text()
paths=re.findall(r'^  "(\$(?:source_dir|test_dir)/[^"]+\.swift)" \\$',text,re.M)
expected=[]
for item in map_data['orderedCompilerInputs']:
    dest=Path(item['destination'])
    expected.append('$test_dir/../LayerStageCandidates/TestSupport.swift' if dest.name=='TestSupport.swift' else
                    '$test_dir/'+dest.name if '/Tests/ConstructorProbes/' in str(dest) else '$source_dir/'+dest.name)
check(paths==expected,'runner compiler source order differs')
check('swiftc -parse-as-library -swift-version 6 -warnings-as-errors' in text,'compiler flags differ')
check('trap \'rm -rf -- "$check_dir"\' EXIT' in text and 'mktemp -d' in text,'temporary compiler ownership missing')
check('"$test_dir/../RegisteredDenseProfiles/retained-inputs.json"' in text,'stdin duplicated or not shared')
check(not list((D/'proposed').rglob('*.json')) and not list((D/'proposed').rglob('*.swift')),'support copied metadata/fixtures')
doc=D/'proposed/experiments/cluster/inference/QWEN_DENSE_CONSTRUCTOR_PROBE.md';body=doc.read_text()
check(body.splitlines()[2]=='> Last updated: 2026-09-14 · commit `e4df336bc`','freshness stamp')
for phrase in ['Actual native probe results are pending','registered_qwen35_9b','registered_qwen38_27b','15 actual source files','passed 11 accepted and 41 rejected','Provider eligibility and M3 arithmetic qualification remain separate and unchanged','materialization remains unwired']:
    check(phrase in body,'scope/contract missing: '+phrase)
links=[]
for target in re.findall(r'\]\(([^)]+)\)',body):
    path=target.split('#')[0]
    if not path or '://' in path: continue
    destination=(R/'experiments/cluster/inference'/path)
    alternate=C/destination.name
    check(destination.exists() or alternate.exists(),'unresolved future source/doc link: '+target)
    links.append(target)
check('ConstructorProbes/run.sh' in (D/'docs.patch').read_text(),'test insertion absent')
result={'schemaVersion':1,'status':'passed','orderedSources':len(paths),'nativeSourceManifestSHA256':sha(manifest),
    'sharedStdinSHA256':stdin['sha256'],'linksChecked':links,'publicRunnerExecuted':False,'swiftCompiled':False,
    'nativeExecuted':False,'modelPayloadRead':False,'proposedSourceMappingVerified':True,'current15CompilerInputBytesVerified':True,
    'expectedFixtureAccepted':11,'expectedFixtureRejected':41}
print(json.dumps(result,indent=2,sort_keys=True))
