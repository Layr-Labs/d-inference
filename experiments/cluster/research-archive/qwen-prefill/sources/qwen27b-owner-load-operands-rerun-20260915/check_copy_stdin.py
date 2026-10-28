"""One real Python child validates the explicit copy input and ordinary owned cleanup."""
import json
from pathlib import Path
import sys
from copy_owned import invoke_controller
from assemble import BASE, pin


def main():
    output = BASE / 'checks-stdin-1'
    output.mkdir(mode=0o700)
    payload = b'closed-manifest\n' + bytes(range(256)) * 513
    (output / 'input').write_bytes(payload)
    receipt = dict(actualPythonChildren=1, modelNativeOrRemoteExecuted=False)
    with (output / 'input').open('rb') as source, (output / 'stdout').open('xb') as out, (output / 'stderr').open('xb') as err:
        invoke_controller([sys.executable, '-B', '-c', 'import sys; value=sys.stdin.buffer.read(); sys.stdout.buffer.write(value)'],
                          out, err, receipt, timeout=5, stdin=source)
    assert (output / 'stdout').read_bytes() == payload
    assert not (output / 'stderr').read_bytes()
    assert receipt['exitCode'] == 0 and receipt['reaped'] and receipt['groupAbsent'] and not receipt['killedOwnedGroup']
    receipt.update(passed=True, inputs=[pin(output / 'input')], stdout=pin(output / 'stdout'), stderr=pin(output / 'stderr'))
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
