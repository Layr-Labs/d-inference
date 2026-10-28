"""Separate bounded phases for the source-reviewed fresh C256 reference retry."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent/'qwen27b-c256-reference-retry-draft-20260917'
PIN = '03f9322384a83e0cf2808940c2a812632925a191a68f190cf4bfe622b2b3b0b5'
sys.path.insert(0,str(ROOT.parent/'cluster-native-shared-hardware-go-qualification-draft-20260917'))
from check_process import run_owned

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase',choices=['source','prepare','copy','run','collect','review'])
    phase = parser.parse_args().phase
    if sha(SOURCE/'manifest.json') != PIN: raise ValueError('Reviewed retry changed')
    for name,row in json.loads((SOURCE/'manifest.json').read_bytes())['files'].items():
        path=SOURCE/name
        if path.is_symlink() or path.stat().st_size!=row['bytes'] or sha(path)!=row['sha256']:
            raise ValueError('Retry member changed')
    prior={'prepare':'source','copy':'prepare','run':'copy','review':'collect'}.get(phase)
    if prior and json.loads((ROOT/('retry-'+prior+'-1/receipt.json')).read_bytes())['status']!='passed':
        raise ValueError('Previous actual phase required')
    if phase in ['copy','run','collect','review']:
        prepared=SOURCE/'prepared/manifest.json'
        preparation=json.loads((ROOT/'retry-prepare-1/receipt.json').read_bytes())
        if sha(prepared)!=preparation['preparedManifestSHA256']:
            raise ValueError('Actually prepared retry manifest changed')
        for name,row in json.loads(prepared.read_bytes())['files'].items():
            path=SOURCE/'prepared'/name
            if path.is_symlink() or path.stat().st_size!=row['bytes'] or sha(path)!=row['sha256']:
                raise ValueError('Actually prepared retry member changed')
    reference=SOURCE/'prepared/reference'
    if phase in ['copy','run','collect']:
        command=['/usr/bin/python3','-B',str(reference/'run_physical.py'),phase]
    else:
        command=['/usr/bin/python3','-B',str(SOURCE/{'source':'check_source.py','prepare':'prepare.py','review':'review_reference.py'}[phase])]
        if phase=='review': command+=['--output',str(SOURCE/'reference-findings-1.json')]
    output=ROOT/('retry-'+phase+'-1');output.mkdir(mode=0o700)
    receipt=dict(status='failed',phase=phase,sourceManifestSHA256=PIN)
    try:
        receipt['execution']=run_owned(command,output,'execution',
            {'source':30,'prepare':30,'copy':60,'run':450,'collect':60,'review':60}[phase])
        if phase in ['copy','run','collect']:
            result=reference/('physical-'+phase+'-1/execution.json')
            if json.loads(result.read_bytes())['passed'] is not True: raise ValueError('Physical phase failed')
            receipt['resultSHA256']=sha(result)
        elif phase=='prepare': receipt['preparedManifestSHA256']=sha(SOURCE/'prepared/manifest.json')
        elif phase=='review':
            result=SOURCE/'reference-findings-1.json'
            if json.loads(result.read_bytes())['evidenceReplayCompleted'] is not True:
                raise ValueError('Independent replay incomplete')
            receipt['findingsSHA256']=sha(result)
        receipt['status']='passed'
    finally:
        with (output/'receipt.json').open('x') as stream:
            json.dump(receipt,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(receipt,sort_keys=True))

if __name__=='__main__':
    os.umask(0o077);main()
