"""Small source/receipt checks only; no binary/model reads or process launches."""
import ast
import argparse
import hashlib
import json
from pathlib import Path
from build_binding import verify

ROOT=Path(__file__).resolve().parent
def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--require-build',action='store_true')
    args=parser.parse_args()
    manifest=json.loads((ROOT/'manifest.json').read_bytes())
    for row in manifest['files']:
        path=ROOT/row['path'];raw=path.read_bytes()
        assert not path.is_symlink() and len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
        if path.suffix=='.py':ast.parse(raw,filename=str(path))
    old=json.loads((ROOT/'predecessor-sources.json').read_bytes())
    for row in old['files']:
        raw=(ROOT/'originals'/row['path']).read_bytes()
        assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
    for name in ('worker_processes.py','worker_contract.py','native_gate.py','reference_resources.py',
                 'mtp_journal.py','jaccl_startup_stderr.py','binding_common.py','expert_retirement.py'):
        assert (ROOT/'package'/name).read_bytes()==(ROOT/'originals/package'/name).read_bytes(),name
    for field in ('projectionSource','prefillSource','descriptionSource','resourceLineage'):
        pin=json.loads((ROOT/'binding-inputs.json').read_bytes())[field]
        raw=Path(pin['path']).read_bytes()
        assert hashlib.sha256(raw).hexdigest()==pin['sha256'],'Source/resource lineage changed'
    bindings=verify() if args.require_build or (ROOT/'artifact-bindings.json').exists() else None
    print(json.dumps(dict(sourceFiles=len(manifest['files']),actualReceiptBindings=bindings is not None,
                          nativeProducts=[x['sha256'] for x in bindings['products']] if bindings else [],
                          activationBlockedUntilActualBuildBinding=bindings is None,
                          testsExecuted=False,payloadsRead=False)))

if __name__=='__main__':main()
