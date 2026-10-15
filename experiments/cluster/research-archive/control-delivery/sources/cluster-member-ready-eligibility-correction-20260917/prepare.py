"""Granted exact one-file overlay into the existing source/cache; no compilation."""
import argparse,json,os
from pathlib import Path
from context import BASE,PRIOR,OUTPUT,WORKSPACE,SOURCE,OLD_HELPER
from guards import verify,recheck_sources,require_preserved_cli,sha,save,require

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--apply',action='store_true',required=True);p.parse_args()
    rows,main,prior,candidate=verify();recheck_sources(prior,main);require_preserved_cli()
    OUTPUT.mkdir(mode=0o700,exist_ok=False)
    for name,source in [('source-before.json',PRIOR/'source-before.json'),('prior-candidate-before.json',PRIOR/'candidate-before.json')]:
        with (OUTPUT/name).open('xb') as f:f.write(source.read_bytes())
    row=rows[0];target=WORKSPACE/row['path'];backup=OUTPUT/'originals'/row['path'];backup.parent.mkdir(parents=True)
    require(not target.is_symlink() and sha(target)==row['beforeSHA256'],'Exact current Service preimage differs')
    with backup.open('xb') as f:f.write(target.read_bytes())
    require(sha(backup)==row['beforeSHA256'],'Preserved Service source differs')
    verify();recheck_sources(prior,main)
    temporary=target.with_name(target.name+'.ready-eligibility.new')
    with temporary.open('xb') as f:f.write(Path(row['sourcePath']).read_bytes());f.flush();os.fsync(f.fileno())
    require(sha(temporary)==row['afterSHA256'] and sha(target)==row['beforeSHA256'],'Source changed before replacement')
    temporary.chmod(target.stat().st_mode & 0o777);os.replace(temporary,target)
    actual,unchanged=recheck_sources(candidate,main);verify();require_preserved_cli()
    save(OUTPUT/'candidate-before.json',actual);save(OUTPUT/'source-after-preparation.json',unchanged)
    save(OUTPUT/'preparation.json',dict(workspace=str(WORKSPACE),source=str(SOURCE),wrapperManifestSHA256=sha(BASE/'manifest.json'),
        integrationSHA256=sha(BASE/'integration.json'),priorCandidateSHA256=sha(PRIOR/'candidate-before.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
        historicalHelperSHA256=sha(OLD_HELPER/'checks.json'),changedFiles=[row['path']],sourceFiles=len(main),candidateFiles=len(candidate),
        workspaceCreated=False,buildCacheCopied=False,compilerRun=False,mainUnchanged=True,correctedHelperRequired=True))
    print(json.dumps(dict(prepared=str(OUTPUT),changedFiles=1,candidateFiles=len(candidate)),sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
