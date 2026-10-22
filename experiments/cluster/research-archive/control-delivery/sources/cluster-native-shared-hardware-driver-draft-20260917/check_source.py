"""Read-only small-source pins/inverse check; no fixture imports or processes."""
import ast
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parent
def require(value,message):
    if not value:raise ValueError(message)
def hash_bytes(raw):return hashlib.sha256(raw).hexdigest()
def replace_once(text,before,after):
    require(text.count(before)==1,'exact inverse segment count')
    return text.replace(before,after,1)
def inverse(path,text):
    if path=='coordinator/cmd/coordinator/main.go':
        text,count=re.subn(r'\n\t// PRIVATE_NATIVE_HARDWARE_BEGIN\n[\s\S]*?\t// PRIVATE_NATIVE_HARDWARE_END\n','\n',text)
        require(count==1,'private main marker')
        return replace_once(text,'serveNativeHardware(hardwareExperiment, httpServer, srv, ctx)','httpServer.ListenAndServe()')
    if path.endswith('/StartCommand+ClusterMember.swift'):
        text,count=re.subn(r'        #if NATIVE_PAIR_HARDWARE_EXPERIMENT\n[\s\S]*?        #endif\n','',text)
        require(count==1,'private leader dispatch');return text
    if path.endswith('/DistributedPipeExecutionOwner.swift'):
        return replace_once(text,'\n#if NATIVE_PAIR_HARDWARE_EXPERIMENT\nextension DistributedPipeRequestLease: DistributedResidentRequestProvenance {\n    var nativeRequestID: UUID { native.requestID }\n}\n#endif\n','')
    if path=='coordinator/registry/native_pair_types.go':
        return replace_once(text,'\tworkerReleaseFailed    [2]bool // private observation only, never a lifecycle gate\n','')
    if path=='coordinator/registry/native_pair_worker.go':
        return replace_once(text,'\ts.workerReleaseFailed = failed // retain the existing actual publication result\n','')
    if path=='provider-swift/Package.swift':
        for target in ('Sources/ProviderCore','Sources/darkbloom','Tests/DarkbloomCLITests'):
            text=replace_once(text,'path: "'+target+'",\n            swiftSettings: [.define("NATIVE_PAIR_HARDWARE_EXPERIMENT")]','path: "'+target+'"')
        return text
    if path.endswith('/CoordinatorClientTypes.swift'):
        text,count=re.subn(r'    #if NATIVE_PAIR_HARDWARE_EXPERIMENT\n[\s\S]*?    #endif\n','',text)
        require(count==1,'private immutable TLS option');return text
    if path.endswith('/CoordinatorClient+Connection.swift') or path.endswith('/ProviderLoop+Serve.swift'):
        text,count=re.subn(r'        #if NATIVE_PAIR_HARDWARE_EXPERIMENT\n[\s\S]*?        #else\n([\s\S]*?)        #endif\n',r'\1',text)
        require(count==1,'private TLS branch');return text
    raise ValueError('unlisted inverse: '+path)

def main():
    pins=json.loads((ROOT/'source-inputs.json').read_bytes())
    for row in pins:
        raw=Path(row['path']).read_bytes()
        require(len(raw)==row['bytes'] and hash_bytes(raw)==row['sha256'],'source pin: '+row['path'])
    contexts=json.loads((ROOT/'context-pins.json').read_bytes())
    for row in contexts:
        raw=Path(row['path']).read_bytes()
        require(len(raw)==row['bytes'] and hash_bytes(raw)==row['sha256'],'context pin: '+row['path'])
    old=json.loads((ROOT/'preimages.json').read_bytes())
    for row in old:
        path=row['path'];raw=(ROOT/'original'/path).read_bytes()
        require(hash_bytes(raw)==row['sha256'] and len(raw)==row['bytes'],'stored preimage '+path)
        require(Path(row['source']).read_bytes()==raw,'actual preimage changed '+path)
        require(inverse(path,(ROOT/'proposed'/path).read_text()).encode()==raw,'source inverse '+path)
    count=0
    for path in ROOT.rglob('*.py'):
        if any(part.startswith('tls-check-') for part in path.parts):continue
        ast.parse(path.read_text(),filename=str(path));count+=1
    print(json.dumps({'sourcePins':len(pins),'contextPins':len(contexts),'exactInverses':len(old),'pythonAST':count,'testsExecuted':False,'compilerExecuted':False,'passed':True},sort_keys=True))

if __name__=='__main__':main()
