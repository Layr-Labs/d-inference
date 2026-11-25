"""Fabricated CPU child only; never used by main() or a physical qualification."""
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True


def main():
    value = json.loads(Path(sys.argv[1]).read_text())
    mode = sys.argv[2]
    value[1]['runtime']['processID'] = os.getpid()
    if mode == 'bad-target':
        value[1]['payload']['targetLoad']['activeTensors'][0]['sourceName'] += '.wrong'
    if mode == 'bad-extra':
        value[1]['payload']['mtpLoad']['placement']['head'][0]['byteCount'] += 1
    if mode == 'bad-target-hash':
        value[1]['payload']['mtpLoad']['targetLoadReceiptSHA256'] = '0'*64
    if mode == 'bad-read-accounting':
        value[1]['payload']['mtpLoad']['sourceReadAccounting']['selectedBytes'] += 1
    if mode == 'bad-free-arithmetic':
        value[1]['releasedResources']['actualFreeBytes'] += 16384
    if mode == 'nonempty-cache':
        value[1]['releasedMemory']['cachedMLXBytes'] = 16384
    if mode == 'missing-retirement':
        value[1]['assistantOwnerReleased'] = False
    for row in value:
        print(json.dumps(row, separators=(',', ':')), flush=True)
    if mode == 'extra-line':
        print('{}', flush=True)
    if mode == 'hang':
        time.sleep(30)
    if mode == 'nonzero':
        return 4
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
