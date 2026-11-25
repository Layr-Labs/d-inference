"""Execute actual local HTTP/owned-child fixtures; no remote/model execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from check_process import run_owned


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--children', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    driver, children, out = args.driver.resolve(), args.children.resolve(), args.output.resolve()
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    binaries = [driver] + [children / name for name in ('InstalledProbeFixture', 'InstalledFakeOwner', 'InstalledFakeWorker')]
    artifacts = binaries + sorted(children.glob('lib*.dylib'))
    def pins():
        return [{'path': str(p), 'sizeBytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in artifacts]
    before = pins()
    (out / 'binary-pins.json').write_text(json.dumps(before, indent=2) + '\n')
    results = []
    for case in ('normal', 'held-response', 'missing-ack', 'nonzero-owner', 'stop-start'):
        case_out = out / case
        case_out.mkdir(mode=0o700)
        os.chdir(case_out)
        receipt = run_owned([str(driver), case] + [str(p) for p in binaries[1:]] + [str(case_out)], case_out, 'run', 70)
        result = json.loads((case_out / 'result.json').read_text())
        if result.get('success') is not True or result.get('nativeModelExecuted') is not False:
            raise ValueError('Actual fixture refused; retain its result and process evidence')
        if before != pins():
            raise ValueError('Executable or adjacent library changed')
        results.append({'case': case, 'result': result, 'process': receipt})
    (out / 'checks.json').write_text(json.dumps({'passed': True, 'cases': results,
        'binaryPinsUnchanged': True, 'nativeModelExecuted': False, 'remoteTransportQualified': False}, indent=2) + '\n')


if __name__ == '__main__':
    main()
