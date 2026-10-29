"""Grant-only 37-path source successor; retain old CLI and reuse the same cache."""
import argparse
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode=True
from context import BASE,ADAPTER,ADAPTER_SHA,PRIOR,ORIGINAL,WORKSPACE,OUTPUT,SOURCE,CORRECTION_SHA
from guards import verify,recheck_sources,require_preserved_cli,sha,save,require
from check_process import run_owned

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--apply',action='store_true',required=True);parser.parse_args()
    rows,before,old,candidate=verify();recheck_sources(old,before)
    history=json.loads((BASE/'qualified-inputs.json').read_text())
    cli=WORKSPACE/'provider-swift/.build/debug/darkbloom'
    require(cli.is_file() and not cli.is_symlink() and cli.stat().st_size==history['priorCLIBytes'] and sha(cli)==history['priorCLI_SHA256'],'Current qualified CLI differs')
    OUTPUT.mkdir(mode=0o700,exist_ok=False)
    (OUTPUT/'qualified-cli').mkdir(mode=0o700)
    copy=run_owned(['/bin/cp','-c',str(cli),str(OUTPUT/'qualified-cli/darkbloom')],OUTPUT,'preserve-qualified-cli',60)
    require_preserved_cli();require(sha(cli)==history['priorCLI_SHA256'],'Original CLI changed during preservation')
    for name,source in [('source-before.json',ORIGINAL/'source-before.json'),('old-candidate-before.json',PRIOR/'candidate-2-before.json')]:
        with (OUTPUT/name).open('xb') as stream:stream.write(source.read_bytes())
    # Retain ALL replaced sources before the first mutation, including bytes
    # that previously produced the qualified CLI. Added paths remain absent.
    for row in rows:
        destination=WORKSPACE/row['path']
        if row['beforeSHA256'] is None:require(not destination.exists() and not destination.is_symlink(),'New path already exists')
        else:
            require(destination.is_file() and not destination.is_symlink() and sha(destination)==row['beforeSHA256'],'Private preimage differs')
            backup=OUTPUT/'originals'/row['path'];backup.parent.mkdir(parents=True,exist_ok=True)
            with backup.open('xb') as stream:stream.write(destination.read_bytes())
            require(sha(backup)==row['beforeSHA256'],'Retained preimage differs')
    verify();recheck_sources(old,before)
    for row in rows:
        destination=WORKSPACE/row['path'];destination.parent.mkdir(parents=True,exist_ok=True)
        temporary=destination.with_name(destination.name+'.retained-request.new')
        data=Path(row['sourcePath']).read_bytes()
        with temporary.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        require(not temporary.is_symlink() and sha(temporary)==row['afterSHA256'],'Staged source differs')
        if row['beforeSHA256'] is None:require(not destination.exists() and not destination.is_symlink(),'New destination appeared')
        else:require(not destination.is_symlink() and sha(destination)==row['beforeSHA256'],'Destination preimage changed')
        os.replace(temporary,destination)
    actual,main=recheck_sources(candidate,before);verify();require_preserved_cli()
    save(OUTPUT/'candidate-before.json',actual);save(OUTPUT/'source-after-preparation.json',main)
    save(OUTPUT/'preparation.json',dict(workspace=str(WORKSPACE),source=str(SOURCE),wrapperManifestSHA256=sha(BASE/'manifest.json'),
        adapterManifestSHA256=ADAPTER_SHA,correctionManifestSHA256=CORRECTION_SHA,integrationSHA256=sha(BASE/'integration.json'),effectiveSourceSHA256=sha(ADAPTER/'integration.json'),
        oldCandidateSHA256=sha(PRIOR/'candidate-2-before.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
        originalPreparationSHA256=sha(ORIGINAL/'preparation.json'),privateWorkspaceStateSHA256=sha(ORIGINAL/'workspace-state-relocated.json'),
        changedFiles=[x['path'] for x in rows],retainedPreimages=23,sourceFiles=len(before),candidateFiles=len(candidate),
        qualifiedCLI_SHA256=history['priorCLI_SHA256'],qualifiedCLIBackup=str(OUTPUT/'qualified-cli/darkbloom'),preservation=copy,
        workspaceCreated=False,buildCacheCopied=False,compilerRun=False,mainUnchanged=True))
    print(json.dumps(dict(prepared=str(OUTPUT),workspace=str(WORKSPACE),changedFiles=len(rows),candidateFiles=len(candidate)),sort_keys=True))
if __name__=='__main__':main()
