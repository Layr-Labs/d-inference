"""Grant-only fixture replacement in the same existing workspace and cache."""
import argparse
import json
import os
from context import BASE,FAILED,RETRY,SOURCE,UPSTREAM_SHA,HELPER_SHA
from guards import verify,recheck,sha,save,require

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--apply',action='store_true',required=True);parser.parse_args()
    row,before,candidate,corrected=verify();recheck(candidate,before)
    require({p for p in candidate if candidate[p]!=corrected[p]}=={row['path']} and set(candidate)==set(corrected),'Exactly one fixture delta')
    RETRY.mkdir(mode=0o700,exist_ok=False)
    for name,source in [('source-before.json',FAILED/'source-before.json'),('failed-candidate-before.json',FAILED/'candidate-before.json')]:
        with (RETRY/name).open('xb') as out:out.write(source.read_bytes())
    destination=FAILED/'workspace'/row['path'];require(not destination.is_symlink() and sha(destination)==row['baseSHA256'],'Live private fixture preimage changed')
    with (RETRY/'original-NativePairMemberControlTests.swift').open('xb') as out:out.write(destination.read_bytes())
    temporary=destination.with_name(destination.name+'.completion-observer.new')
    with temporary.open('xb') as out:
        out.write((BASE/'proposed/NativePairMemberControlTests.swift').read_bytes());out.flush();os.fsync(out.fileno())
    require(sha(temporary)==row['proposedSHA256'] and sha(destination)==row['baseSHA256'] and not destination.is_symlink(),'Staged fixture/preimage changed')
    os.replace(temporary,destination)
    actual,main=recheck(corrected,before);verify()
    save(RETRY/'candidate-2-before.json',actual);save(RETRY/'source-after-preparation.json',main)
    save(RETRY/'preparation.json',dict(source=str(SOURCE),workspace=str(FAILED/'workspace'),wrapperManifestSHA256=sha(BASE/'manifest.json'),originalManifestSHA256=UPSTREAM_SHA,qualifiedHelperSHA256=HELPER_SHA,originalPreparationSHA256=sha(FAILED/'preparation.json'),failureInputsSHA256=sha(BASE/'failure-inputs.json'),candidate2SHA256=sha(RETRY/'candidate-2-before.json'),changedFiles=[row['path']],sourceFiles=len(before),candidateFiles=len(corrected),compilerRun=False,helperRecompiled=False,workspaceCreated=False,buildCacheCopied=False,mainUnchanged=True))
    print(json.dumps(dict(prepared=str(RETRY),workspace=str(FAILED/'workspace'),candidate2SHA256=sha(RETRY/'candidate-2-before.json'),changedFiles=[row['path']]),sort_keys=True))
if __name__=='__main__':main()
