#!/usr/bin/env python3
"""Compile only Foundation/CryptoKit modules and CPU fixtures, never SwiftPM/MLX."""
import argparse, hashlib, json, subprocess, time
from pathlib import Path
p=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=False,exist_ok=False)
listing=json.loads((p/'fixture-source-list.json').read_text());groups={}
for name,records in listing['groups'].items():
    groups[name]=[]
    for row in records:
        f=Path(row['path'])
        if hashlib.sha256(f.read_bytes()).hexdigest()!=row['sha256']:raise ValueError('Source changed: '+str(f))
        groups[name].append(str(f))
results=[]
def run(name,cmd):
    began=time.monotonic()
    with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
        r=subprocess.run(cmd,cwd=out,stdout=stdout,stderr=stderr,timeout=60)
    results.append({'name':name,'exitCode':r.returncode,'seconds':time.monotonic()-began})
    (out/'checks.json').write_text(json.dumps({'checks':results,'nativeOrNetworkExecuted':False},indent=2)+'\n')
    print(name,r.returncode,flush=True)
    if r.returncode or (out/(name+'.stderr')).stat().st_size:
        print((out/(name+'.stderr')).read_text());raise RuntimeError(name)
base=['swiftc','-swift-version','6','-warnings-as-errors','-target','arm64-apple-macos14.0']
dependencies={'DarkbloomClusterProtocol':[],'DarkbloomClusterBootstrap':[],'DarkbloomClusterProcess':['DarkbloomClusterProtocol'],'DarkbloomClusterRemote':['DarkbloomClusterProtocol','DarkbloomClusterBootstrap','DarkbloomClusterProcess'],'MLXLMCommon':[],'ProviderCoreFoundation':[],'InstalledContract':['DarkbloomClusterProtocol','DarkbloomClusterBootstrap','DarkbloomClusterProcess','DarkbloomClusterRemote','MLXLMCommon','ProviderCoreFoundation']}
for name,sources in groups.items():
    links=['-I',str(out),'-L',str(out),'-Xlinker','-rpath','-Xlinker',str(out)]+['-l'+d for d in dependencies[name]]
    run(name,base+['-emit-library','-emit-module','-enable-testing','-module-name',name,'-emit-module-path',str(out/(name+'.swiftmodule'))]+links+sources+['-o',str(out/('lib'+name+'.dylib')),'-Xlinker','-install_name','-Xlinker','@rpath/lib'+name+'.dylib'])

for name, records in listing.get("fixtures", {}).items():
    sources=[]
    for row in records:
        source=Path(row["path"])
        if hashlib.sha256(source.read_bytes()).hexdigest()!=row["sha256"]:raise ValueError("Fixture changed: "+str(source))
        sources.append(str(source))
    links=["-I",str(out),"-L",str(out),"-Xlinker","-rpath","-Xlinker",str(out)]+["-l"+name for name in groups]
    run(name,base+["-parse-as-library"]+links+sources+["-o",str(out/name)])
run("installed-session-test",[str(out/"InstalledSessionCheck"),str(out/"InstalledProbeFixture"),str(out/"InstalledFakeOwner"),str(out/"InstalledFakeWorker")])
