"""Granted one-file incremental correction; no cache copy or compiler invocation."""
import argparse,json,os
from pathlib import Path
from context import BASE,PRIOR,OUTPUT,WORKSPACE,SOURCE
from guards import verify,recheck_sources,require_preserved_cli,require_helper,sha,save,require

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--apply',action='store_true',required=True);p.parse_args()
    rows,before,prior,candidate=verify();recheck_sources(prior,before);require_preserved_cli();require_helper()
    OUTPUT.mkdir(mode=0o700,exist_ok=False)
    for name,source in [('source-before.json',PRIOR/'source-before.json'),('prior-candidate-before.json',PRIOR/'candidate-before.json')]:
        with (OUTPUT/name).open('xb') as f:f.write(source.read_bytes())
    row=rows[0];destination=WORKSPACE/row['path'];backup=OUTPUT/'originals'/row['path'];backup.parent.mkdir(parents=True)
    require(not destination.is_symlink() and sha(destination)==row['beforeSHA256'],'Exact current CLI preimage differs')
    with backup.open('xb') as f:f.write(destination.read_bytes())
    require(sha(backup)==row['beforeSHA256'],'Preserved preimage changed')
    verify();recheck_sources(prior,before)
    temporary=destination.with_name(destination.name+'.actor-install.new')
    with temporary.open('xb') as f:f.write(Path(row['sourcePath']).read_bytes());f.flush();os.fsync(f.fileno())
    require(sha(temporary)==row['afterSHA256'] and sha(destination)==row['beforeSHA256'],'Source changed before replacement')
    temporary.chmod(destination.stat().st_mode & 0o777);os.replace(temporary,destination)
    actual,main=recheck_sources(candidate,before);verify();require_helper();require_preserved_cli()
    save(OUTPUT/'candidate-before.json',actual);save(OUTPUT/'source-after-preparation.json',main)
    save(OUTPUT/'preparation.json',dict(workspace=str(WORKSPACE),source=str(SOURCE),wrapperManifestSHA256=sha(BASE/'manifest.json'),
        integrationSHA256=sha(BASE/'integration.json'),priorCandidateSHA256=sha(PRIOR/'candidate-before.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
        reusedHelperSHA256=sha(PRIOR/'helper-1/checks.json'),changedFiles=[row['path']],sourceFiles=len(before),candidateFiles=len(candidate),
        workspaceCreated=False,buildCacheCopied=False,helperRebuilt=False,compilerRun=False,mainUnchanged=True))
    print(json.dumps(dict(prepared=str(OUTPUT),workspace=str(WORKSPACE),changedFiles=1,candidateFiles=len(candidate)),sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
