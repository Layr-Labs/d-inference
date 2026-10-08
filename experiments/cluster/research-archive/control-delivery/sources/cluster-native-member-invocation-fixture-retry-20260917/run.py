"""Bounded tests then matching CLI build; never rebuild the qualified helper."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import sys
sys.dont_write_bytecode=True
from context import BASE,FAILED,RETRY,SOURCE,HELPER_SHA,UPSTREAM_SHA,SWIFT_FILTER,INVOCATION_METHODS,isolated_environment
from guards import verify,recheck,sha,save,require
from check_process import run_owned
from corrected_results import validate_swift_results

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--phase',choices=['tests','build'],required=True);parser.add_argument('--prepared',type=Path,required=True);parser.add_argument('--attempt',type=int,required=True);args=parser.parse_args()
    require(args.prepared.resolve()==RETRY and 2<=args.attempt<=9,'Exact prepared retry/attempt bound')
    row,before,old,candidate=verify();recheck(candidate,before)
    preparation=json.loads((RETRY/'preparation.json').read_text())
    require(preparation['wrapperManifestSHA256']==sha(BASE/'manifest.json') and preparation['originalManifestSHA256']==UPSTREAM_SHA and preparation['qualifiedHelperSHA256']==HELPER_SHA and preparation['workspace']==str(FAILED/'workspace') and preparation['source']==str(SOURCE),'Retry preparation binding')
    require(preparation['candidate2SHA256']==sha(RETRY/'candidate-2-before.json') and json.loads((RETRY/'candidate-2-before.json').read_text())==candidate,'Corrected candidate binding')
    if args.phase=='build':
        prior=RETRY/('tests-'+str(args.attempt));value=json.loads((prior/'checks.json').read_text())
        require(value['passed'] and value['wrapperManifestSHA256']==sha(BASE/'manifest.json') and value['candidate2SHA256']==preparation['candidate2SHA256'] and value['qualifiedHelperSHA256']==HELPER_SHA and value['details']['invocationMethodsPassed']==len(INVOCATION_METHODS) and value['executionSHA256']==sha(prior/'execution.json'),'Matching complete corrected tests required')
    output=RETRY/(args.phase+'-'+str(args.attempt));output.mkdir(mode=0o700,exist_ok=False)
    isolated_environment();os.chdir(FAILED/'workspace/provider-swift')
    command=['swift','test' if args.phase=='tests' else 'build','-j','2','--disable-automatic-resolution','--disable-build-manifest-caching']
    if args.phase=='tests':
        evidence=output/'owned-native-evidence';evidence.mkdir(mode=0o700)
        os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE']=str(FAILED/'helper-1/native-member-fixture');os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE']=str(evidence)
        command+=['--filter',SWIFT_FILTER]
    else:command+=['--product','darkbloom']
    limit=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,limit[1]))
    try:step=run_owned(command,output,'execution',900)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,limit);verify();actual,main=recheck(candidate,before)
        save(output/'candidate-2-after.json',actual);save(output/'source-after.json',main)
        save(output/'source-recheck.json',dict(unchanged=True,qualifiedHelperUnchanged=True,onlyFixtureChanged=True,candidateAfterSHA256=sha(output/'candidate-2-after.json'),sourceAfterSHA256=sha(output/'source-after.json')))
    if args.phase=='tests':
        raw=(output/'execution.stdout').read_text()+'\n'+(output/'execution.stderr').read_text();details=validate_swift_results(raw)
        for name in INVOCATION_METHODS:
            require(len(re.findall(r'(?m)^✔ Test '+re.escape(name)+r'\(\) passed after [^\n]+$',raw))==1,'Invocation case absent/repeated: '+name)
        details['invocationMethodsPassed']=len(INVOCATION_METHODS)
    else:
        binary=FAILED/'workspace/provider-swift/.build/debug/darkbloom';details=dict(binarySHA256=sha(binary),binaryBytes=binary.stat().st_size,binaryExecuted=False)
    save(output/'checks.json',dict(passed=True,phase=args.phase,details=details,step=step,wrapperManifestSHA256=sha(BASE/'manifest.json'),candidate2SHA256=preparation['candidate2SHA256'],qualifiedHelperSHA256=HELPER_SHA,executionSHA256=sha(output/'execution.json'),modelOrRDMAOrRemoteExecuted=False,productionMembershipQualified=False))
    print(json.dumps(details,sort_keys=True))
if __name__=='__main__':main()
