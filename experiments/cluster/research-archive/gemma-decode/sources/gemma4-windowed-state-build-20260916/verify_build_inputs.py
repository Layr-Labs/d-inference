"""Exact inventory including additions, before and after each bounded build."""
import json
from build_inputs import BASE,WORKSPACE,SCRATCH,inputs,entries

def verify():
    inputs();counts={}
    for name,root in [('source-snapshot-1.json',WORKSPACE),('dependency-snapshot-1.json',SCRATCH/'checkouts')]:
        expected=json.loads((BASE/name).read_bytes())['members']
        if entries(root)!=expected:raise ValueError('Build source/dependency inventory changed: '+name)
        counts[name]=len(expected)
    return counts
if __name__=='__main__':print(json.dumps(verify(),sort_keys=True))
