"""Compare only explicitly pinned complete Gemma native evidence, without execution."""
import argparse
import json
from pathlib import Path
import sys
sys.dont_write_bytecode=True
from contract import MODES, canonical_path, expected_description, fields, pinned
from recorded_math import canonical, digest, equal, parse_json, require, sha_string
from report import report
from snapshot import snapshot
from state import compare_states


def compare(packet):
    fields(packet,'schema expected prompt results')
    equal(packet['schema'],'gemma4_short_comparison_packet_v1','Comparison packet schema')
    fields(packet['results'],'full stage0 stage1')
    expected_file=pinned(packet['expected'],65_536)
    prompt_file=pinned(packet['prompt'],4096)
    expected=parse_json(expected_file['raw'])
    prompt=expected_description(expected,prompt_file['raw'])
    # A valid pinned full reference is mandatory before staged files are read.
    full=report(packet['results']['full'],expected,prompt,0)
    left=report(packet['results']['stage0'],expected,prompt,1)
    right=report(packet['results']['stage1'],expected,prompt,2)
    equal(left['tokens'],full['tokens'],'Stage0 accepted token sequence differs')
    equal(right['tokens'],full['tokens'],'Stage1 accepted token sequence differs')
    for ordinal in range(2):
        require(full['rows'][ordinal]==right['rows'][ordinal],f'Full native row differs at frontier {32+ordinal}')
    for sequence in range(3):
        equal(left['frames'][sequence],right['frames'][sequence],'Actual peer boundary identity differs')
    compare_states(full['state'],left['state'],right['state'])
    for index,layer in enumerate(left['layers']+right['layers']):
        other=dict(layer);other['localIndex']=index
        equal(other,full['layers'][index],'Actual global native dtype/geometry differs')
    return dict(schema='gemma4_short_numeric_comparison_v1',passed=True,
        expectedSHA256=expected_file['sha256'],promptFileSHA256=prompt_file['sha256'],
        scopeSHA256=expected['scopeSHA256'],planSHA256=expected['planSHA256'],
        buildIdentitySHA256=expected['buildIdentitySHA256'],requestSHA256=expected['requestSHA256'],
        membershipEpoch=expected['membershipEpoch'],requestID=expected['requestID'],
        selectedTokenIDs=full['tokens'],fullVocabularyRows=2,vocabularySize=262_144,
        comparedStateEntries=90,finalFrontier=33,maximumTokens=34,
        exactNativeLogicalBytes=True,toleranceApplied=False,
        inputs={mode:value['receipt'] for mode,value in zip(MODES,(full,left,right))},
        actualModelOrCompilerExecutedByComparator=False,physicalProcessOrLeaseRetirementEstablished=False,
        independentPhysicalResourceValidationEstablished=False,fullSourceOrBuildRevalidated=False,
        runtimeServingEnabled=False,throughputMeasurementValid=False,encryptedRDMAEstablished=False)


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--packet',required=True)
    parser.add_argument('--packet-sha256',required=True)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    packet=pinned(dict(path=args.packet,sha256=sha_string(args.packet_sha256)),16_384)
    output=args.output
    require(output.is_absolute() and output.parent.resolve()==output.parent and not output.exists(),
            'Output must be create-only beneath a canonical parent')
    result=compare(parse_json(packet['raw']))
    result['packetSHA256']=packet['sha256']
    raw=json.dumps(result,sort_keys=True,indent=2,allow_nan=False).encode()+b'\n'
    require(len(raw)<=262_144,'Comparison report bound')
    with output.open('xb') as stream:
        stream.write(raw)
    print(json.dumps(dict(passed=True,output=str(output),sha256=digest(raw)),sort_keys=True))


if __name__=='__main__':main()
