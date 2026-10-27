"""Root-only small rebind. No native invocation or model/remote operation."""
import json
from pathlib import Path
from check_process import run_owned
from check_source import check, sha

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'gemma4-attention-identity-physical-draft-20260917'


def main():
    check()
    output = BASE / 'preparation-1'; output.mkdir(mode=0o700)
    inputs = OLD / 'actual-inputs-1/inputs.json'
    wanted = 'cc47108a34deab1b50425524e9a8421954efb31af366a787ffda26c6b88f9973'
    if sha(inputs) != wanted: raise ValueError('Original actual describe/build inputs changed')
    receipt = dict(status='failed', sourceManifestSHA256=sha(BASE / 'source/manifest.json'),
                   draftManifestSHA256=sha(BASE / 'manifest.json'), nativeExecuted=False, remoteExecuted=False)
    try:
        receipt['child'] = run_owned(['/usr/bin/python3', '-B', str(BASE / 'source/bind_build.py'),
            '--inputs', str(inputs), '--inputs-sha256', wanted, '--output', str(BASE / 'bound')], output, 'bind', 30)
        if (BASE / 'bound/binding.json').read_bytes() != (OLD / 'actual-inputs-1/bound/binding.json').read_bytes():
            raise ValueError('Supervisor-only successor changed numerical/native binding')
        check()
        receipt.update(status='passed', bindingReceiptSHA256=sha(BASE / 'bound/binding-receipt.json'))
    finally:
        with (output / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, sort_keys=True, indent=2); stream.write('\n')
    print(json.dumps(dict(status='passed', receiptSHA256=sha(output / 'receipt.json'))))


if __name__ == '__main__': main()
