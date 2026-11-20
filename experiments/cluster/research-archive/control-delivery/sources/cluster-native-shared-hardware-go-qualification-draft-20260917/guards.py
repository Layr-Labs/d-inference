"""Exact prior qualification and bounded same-workspace source guards."""
import hashlib
import json
import os
from pathlib import Path
import re
from inputs import BASE,ANCESTOR,WORKSPACE,DRIVER,DRIVER_SHA

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while data:=f.read(1024*1024):h.update(data)
    return h.hexdigest()
def save(path,value):
    with path.open('x') as f:json.dump(value,f,indent=2,sort_keys=True);f.write('\n')
def check_file(path,pin,size=None):
    if not path.is_file() or path.is_symlink() or (size is not None and path.stat().st_size!=size) or sha(path)!=pin:raise ValueError('pinned regular file differs: '+str(path))
def load(name):return json.loads((BASE/name).read_bytes())
def check_inputs():
    manifest=BASE/'manifest.json'
    if manifest.exists():
        for row in json.loads(manifest.read_bytes())['files']:check_file(BASE/row['path'],row['sha256'],row['bytes'])
    for row in load('context-pins.json'):check_file(Path(row['path']),row['sha256'],row['bytes'])
    if sha(DRIVER/'manifest.json')!=DRIVER_SHA:raise ValueError('driver freeze changed')
    for row in json.loads((DRIVER/'manifest.json').read_bytes())['members']:check_file(DRIVER/row['path'],row['sha256'],row['bytes'])
    old=load('ancestor-source.json');actual=json.loads((ANCESTOR/'source-before.json').read_bytes())
    if old!=actual or len(old['files'])!=1125:raise ValueError('qualified original source inventory differs')
    qualified=json.loads((ANCESTOR/'go-all-1/checks.json').read_bytes())
    if qualified.get('passed') is not True or qualified['details']['passedMethods']!=2806 or qualified['details']['totalMethods']!=2809 or qualified.get('sourcePinsUnchanged') is not True:raise ValueError('actual prior full qualification missing')
    for row in load('integration.json')['files']:check_file(Path(row['sourcePath']),row['sha256'],row['sizeBytes'])
    packages=set(load('projected-source.json')['packages'])
    # The only new local packages are the command and its existing config.
    for row in load('integration.json')['files']:
        text=Path(row['sourcePath']).read_text()
        for local in re.findall(r'"github.com/eigeninference/d-inference/([^"\n]+)"',text):
            if local not in packages:raise ValueError('unbound command dependency: '+local)
        if '//go:embed' in text:raise ValueError('new embedding requires explicit closure')
    return old

def verify_workspace(snapshot):
    if WORKSPACE.is_symlink() or WORKSPACE.resolve()!=WORKSPACE:raise ValueError('workspace is not exact canonical ancestor')
    for row in snapshot['files']:check_file(WORKSPACE/row['path'],row['sha256'],row['sizeBytes'])
    expected={row['path'] for row in snapshot['files']}
    # Preserve known optional old binaries; new products are always elsewhere.
    allowed={'bin/coordinator','coordinator-bin'}
    actual=set()
    for path in WORKSPACE.rglob('*'):
        if path.is_symlink():raise ValueError('workspace symlink')
        if path.is_file():actual.add(path.relative_to(WORKSPACE).as_posix())
    if actual-expected-allowed or expected-actual:raise ValueError('unlisted source/fixture paths')

def check_preimage(row):
    path=WORKSPACE/row['path'];expected=row['beforeSHA256']
    if expected is None:
        if path.exists() or path.is_symlink():raise ValueError('expected absent overlay path: '+str(path))
    else:check_file(path,expected)

def check_prepared():
    check_inputs()
    p=BASE/'preparation';receipt=json.loads((p/'receipt.json').read_bytes())
    if receipt.get('passed') is not True or receipt['projectedSourceSHA256']!=sha(BASE/'projected-source.json') or receipt['workspace']!=str(WORKSPACE):raise ValueError('matching preparation required')
    verify_workspace(load('projected-source.json'))
    for row in receipt['preservedBinaries']:
        check_file(Path(row['path']),row['sha256'],row['bytes']);check_file(p/row['backup'],row['sha256'],row['bytes'])
    return receipt

def isolated_environment():
    keep=('PATH','HOME','USER','LOGNAME','TMPDIR','LANG','LC_ALL','DEVELOPER_DIR','SDKROOT')
    selected={k:os.environ[k] for k in keep if k in os.environ}
    selected.update(GOMAXPROCS='2',GOPROXY='off',GOSUMDB='off',GOTOOLCHAIN='local',GOWORK='off',GOFLAGS='-mod=readonly')
    os.environ.clear();os.environ.update(selected)
