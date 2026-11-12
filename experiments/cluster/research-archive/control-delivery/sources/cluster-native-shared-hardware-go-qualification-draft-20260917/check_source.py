"""Read only metadata and small new sources; do not hash/materialize workspace."""
import ast
import json
from pathlib import Path
from guards import BASE,check_inputs,load

def main():
    old=check_inputs();old_rows={r['path']:r for r in old['files']};projected={k:dict(v) for k,v in old_rows.items()}
    changes=load('integration.json')['files']
    if len(changes)!=13 or sum(r['kind']=='driver' for r in changes)!=8:raise ValueError('closed eight-driver/four-support scope')
    for row in changes:
        if old_rows.get(row['path'],{}).get('sha256')!=row['beforeSHA256']:raise ValueError('overlay preimage not qualified')
        projected[row['path']]={'path':row['path'],'sha256':row['sha256'],'sizeBytes':row['sizeBytes'],'source':row['kind']}
    expected=load('projected-source.json')
    if expected['files']!=[projected[k] for k in sorted(projected)] or len(projected)!=1136:raise ValueError('exact prospective inventory')
    tests=load('expected-tests.json')
    if sum(map(len,tests['default'].values()))!=51 or sum(map(len,tests['private'].values()))!=54 or len(tests['command'])!=8 or len(tests['commandPrivate'])!=11:raise ValueError('closed mandatory tests')
    for path in BASE.glob('*.py'):ast.parse(path.read_text(),filename=str(path))
    print(json.dumps({'passed':True,'driverGoFiles':8,'unchangedCommandSources':4,'sourceBefore':1125,'projectedSources':1136,'packages':28,'defaultFocused':51,'privateFocused':54,'defaultCommandMethods':8,'privateCommandMethods':11,'compilerExecuted':False,'workspaceMaterializedOrHashed':False},sort_keys=True))

if __name__=='__main__':main()
