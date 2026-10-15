"""Granted exact17-path source update; preserve failed binary and every preimage."""
import argparse,json,os
from pathlib import Path
from context import BASE,PRIOR,OUTPUT,WORKSPACE,SOURCE,OLD_HELPER
from guards import verify,recheck_sources,require_preserved_cli,sha,save,require
from activation import require_activation
from check_process import run_owned

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--apply',action='store_true',required=True);p.parse_args()
    rows,main,before,candidate=verify();activation=require_activation();recheck_sources(before,main)
    binary=WORKSPACE/'provider-swift/.build/debug/darkbloom'
    require(not binary.is_symlink() and sha(binary)==activation['priorBinarySHA256'],'Current unqualified binary differs')
    OUTPUT.mkdir(mode=0o700);receipt=dict(status='failed',compilerRun=False,workspaceCreated=False,buildCacheCopied=False)
    try:
        (OUTPUT/'prior-binary').mkdir(mode=0o700)
        receipt['preservation']=run_owned(['/bin/cp','-c',str(binary),str(OUTPUT/'prior-binary/darkbloom')],OUTPUT,'preserve-prior-binary',60)
        require_preserved_cli()
        for name,source in [('source-before.json',PRIOR/'source-before.json'),('prior-candidate-before.json',PRIOR/'candidate-before.json')]:
            with (OUTPUT/name).open('xb') as f:f.write(source.read_bytes())
        for row in rows:
            path=WORKSPACE/row['path']
            if row['beforeSHA256'] is None:require(not path.exists() and not path.is_symlink(),'New source path already exists')
            else:
                require(not path.is_symlink() and sha(path)==row['beforeSHA256'],'Exact source preimage differs')
                backup=OUTPUT/'originals'/row['path'];backup.parent.mkdir(parents=True,exist_ok=True)
                with backup.open('xb') as f:f.write(path.read_bytes())
                require(sha(backup)==row['beforeSHA256'],'Preserved source preimage differs')
        verify();require_activation();recheck_sources(before,main)
        for row in rows:
            path=WORKSPACE/row['path'];path.parent.mkdir(parents=True,exist_ok=True)
            temporary=path.with_name(path.name+'.numerical-provider.new')
            with temporary.open('xb') as f:f.write(Path(row['sourcePath']).read_bytes());f.flush();os.fsync(f.fileno())
            require(sha(temporary)==row['afterSHA256'],'Prepared source bytes differ')
            if row['beforeSHA256'] is None:
                os.link(temporary,path);temporary.unlink()
            else:
                require(not path.is_symlink() and sha(path)==row['beforeSHA256'],'Preimage changed before replacement');os.replace(temporary,path)
        actual,unchanged=recheck_sources(candidate,main);verify();require_activation();require_preserved_cli()
        save(OUTPUT/'candidate-before.json',actual);save(OUTPUT/'source-after-preparation.json',unchanged)
        receipt.update(status='passed',workspace=str(WORKSPACE),source=str(SOURCE),wrapperManifestSHA256=sha(BASE/'manifest.json'),
            integrationSHA256=sha(BASE/'integration.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
            historicalHelperSHA256=sha(OLD_HELPER/'checks.json'),activationSHA256=sha(BASE/'activation-1/activation.json'),
            changedFiles=[r['path'] for r in rows],retainedPreimages=sum(r['beforeSHA256'] is not None for r in rows),sourceFiles=len(main),candidateFiles=len(candidate),mainUnchanged=True,correctedHelperRequired=True)
    finally:save(OUTPUT/'preparation.json',receipt)
    print(json.dumps(receipt,sort_keys=True))

if __name__=='__main__':os.umask(0o077);main()
