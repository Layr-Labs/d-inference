"""Actual CPU child for parent cleanup tests; no native/model imports."""
import json
import os
import sys
import time

first,final=json.load(open(sys.argv[1]))
mode=sys.argv[2]
final['runtime']['processID']=os.getpid()
print(json.dumps(first),flush=True)
if mode=='stall':time.sleep(20)
if mode!='missing':print(json.dumps(final),flush=True)
if mode=='extra':print('{}',flush=True)
if mode=='nonzero':sys.exit(7)
