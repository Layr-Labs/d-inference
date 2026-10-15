"""Small source/AST/projection checks only: no compiler, child fixtures or inventory walk."""
import ast,hashlib,json
from pathlib import Path
from context import BASE,ELIGIBILITY,DRAIN,DRIVER,NUMERICAL,TLS_COMPOSITION,ADAPTER
from guards import verify,sha,require

def check(*,own=True):
    rows,main,before,after=verify(own=own)
    for p in BASE.glob('*.py'):ast.parse(p.read_text(),filename=str(p))
    reused=['owned_process.py','check_process.py','source_inventory.py','corrected_results.py','prepare_owned.py','prior-coverage.json','discovered-coverage.json']
    for name in reused:require(sha(BASE/name)==sha(ELIGIBILITY/name),'Reused helper changed: '+name)
    required=json.loads((BASE/'coverage.json').read_text())
    previous=json.loads((BASE/'discovered-coverage.json').read_text())['completionLabels']
    require(required['completionLabels']==sorted(previous+[x+'()' for x in required['newMethods']])
        and required['tests']==117 and required['suites']==19,'Exact previous112 plus five required')
    test_paths=[Path(x['sourcePath']) for x in rows if '/Tests/' in x['path']]
    names=[]
    for p in test_paths:
        import re
        names.extend(re.findall(r'\bfunc\s+(\w+)\s*\(',p.read_text()))
    require(all(x in names for x in required['newMethods']),'New required test method absent from actual proposed sources')
    require((len(main),len(before),len(after),sum(x['beforeSHA256'] is None for x in rows))==(13821,13853,13859,6),'Source projection count differs')
    runtime='libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterWorkerOwnerService.swift'
    require(before[runtime]==after[runtime]=={'sha256':'628ac962efb0733129e330d6409c89240351d4cdff552d1cd12b614794f23ee7'},'Eligibility Service changed')
    return dict(sourceOnly=True,overlayFiles=len(rows),newFiles=6,replacedFiles=11,sourceFiles=len(main),candidateFiles=len(after),
        exactReusedFiles=len(reused),expectedProviderTests=117,expectedProviderSuites=19,standaloneDrainGroups=4,
        baselineDrainReproductionRequired=True,helperSteps=23,materializationExecuted=False,compilerExecuted=False,fixtureExecuted=False,
        integrationSHA256=sha(BASE/'integration.json'))

if __name__=='__main__':print(json.dumps(check(),sort_keys=True))
