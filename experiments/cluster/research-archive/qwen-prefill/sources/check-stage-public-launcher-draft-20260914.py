"""CPU-only draft check: saved JSON/metadata, fake lifecycle, no native/model IO."""
import ast
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
DRAFT=ROOT/'stage-public-launcher-draft'
sys.path.insert(0,str(DRAFT))
from stage_checks import baseline,p2p,ranks,request
from stage_checks.common import parse,require,digest
from stage_checks.stream import Records


def file_hash(path):return digest(path.read_bytes())

def rejects(name,object,key,value,operation):
    original=object[key];object[key]=value
    try:
        try:operation()
        except ValueError:return name
        raise AssertionError('Invalid saved-record mutation was accepted: '+name)
    finally:object[key]=original


def check():
    result=dict(kind='stage_public_launcher_draft_cpu_check',schema_version=1,
        native_execution=False,model_payload_reads=False,repository_mutated=False,
        socket_execution=False,historical_audits_replaced=False)
    paths=sorted(p for p in DRAFT.rglob('*') if p.is_file() and p.suffix in ('.py','.md'))
    for path in paths:
        if path.suffix=='.py':ast.parse(path.read_text(),filename=str(path))
    result['source_sha256']={p.relative_to(DRAFT).as_posix():file_hash(p)for p in paths}
    result['ast_parse_passed']=True
    result['checker_sha256']=file_hash(Path(__file__))
    output=io.StringIO()
    suite=unittest.defaultTestLoader.discover(str(DRAFT),pattern='test_stage*.py')
    tested=unittest.TextTestRunner(stream=output,verbosity=2).run(suite)
    (DRAFT/'cpu-tests.log').write_text(output.getvalue())
    require(tested.wasSuccessful(),'Fake/pure CPU tests failed')
    result.update(tests_passed=tested.testsRun,tests_failed=0,cpu_tests_log_sha256=file_hash(DRAFT/'cpu-tests.log'))
    preserved=[]
    for name in ('stage-p2p-launcher-draft','stage-rank-launcher-draft'):
        manifest=ROOT/name/'draft-cpu-check-receipt.json';old=parse(manifest.read_bytes())
        for filename,expected in old['source_sha256'].items():
            require(file_hash(manifest.parent/filename)==expected,'Frozen launcher drift: '+filename)
        preserved.append(dict(path=str(manifest),sha256=file_hash(manifest),source_files=len(old['source_sha256'])))
    result['preserved_historical_manifests']=preserved
    compatible=[];negatives=[]
    for mode,name,namespace in [('p2p','stage-p2p-success-20260914',p2p),('ranks','qwen-layer-stage-ranks-20260914',ranks)]:
        folder=ROOT/'runs'/name;receipt=parse((folder/'receipt.json').read_bytes());epoch=receipt['epoch']
        context=dict(mode=mode);input_paths=[folder/'receipt.json']
        if mode=='ranks':
            raw=(folder/'model-config.json').read_bytes();config=parse(raw);text=config['text_config']
            prompt=parse((folder/'inputs/prompt.json').read_bytes());teacher=parse((folder/'inputs/teacher.json').read_bytes())
            config_path=folder/'rank-0/rank.json';arguments=parse(config_path.read_bytes())['arguments']
            chunk=int(arguments[arguments.index('--chunk-size')+1])
            recorded,fingerprint=request.make_request(epoch,prompt,teacher,chunk,text['vocab_size'])
            context.update(configuration=config,text=text,artifact=receipt['artifact_aggregate_sha256'],
                configuration_sha256=digest(raw),vocabulary=text['vocab_size'],request=recorded,request_fingerprint=fingerprint)
            input_paths += [folder/'model-config.json',folder/'inputs/prompt.json',folder/'inputs/teacher.json',config_path]
        readers=[Records(folder/f'rank-{rank}',rank,epoch,context,namespace)for rank in (0,1)]
        for reader in readers:reader.poll(final=True)
        reports=[reader.terminal for reader in readers]
        validation=namespace.pair(reports,context)
        input_paths += [folder/f'rank-{rank}/stdout.jsonl'for rank in (0,1)]
        detail=dict(mode=mode,validation=validation,inputs_sha256={str(p):file_hash(p)for p in input_paths})
        validate=lambda:namespace.validate(reports[0],0,epoch,context)
        compare=lambda:namespace.pair(reports,context)
        negatives.append(rejects(mode+':unsupported-schema',reports[0],'schemaVersion',2,validate))
        if mode=='p2p':
            negatives.append(rejects('p2p:peer-fixture-mismatch',reports[1],'fixtureFingerprint','f'*64,compare))
        else:
            capture=reports[0]['frames'][0]['capture']
            negatives.append(rejects('ranks:wrong-state-frontier',capture,'committedTokens',1,validate))
            negatives.append(rejects('ranks:wrong-request-teacher',reports[0]['request'],'teacherTokenIDs',[0,0,0],validate))
            negatives.append(rejects('ranks:wrong-common-storage-schema',reports[0]['sourceLoad']['storageCommitment'],'schemaVersion',2,compare))
            negatives.append(rejects('ranks:peer-residual-mismatch',reports[1]['frames'][0]['capture'],'boundaryPayloadSHA256','f'*64,compare))
            logits=reports[1]['frames'][-1]['capture']['logits']
            negatives.append(rejects('ranks:corrupt-native-logit-hash',logits,'logicalBytesSHA256','f'*64,
                lambda:namespace.validate(reports[1],1,epoch,context)))
            reference=ROOT/'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt'
            context['baseline_sha256']=file_hash(reference)
            detail['optional_pinned_baseline_comparison']=baseline.compare(reference,reports,context)
            detail['baseline_input']=dict(path=str(reference),sha256=file_hash(reference))
            negatives.append(rejects('baseline:wrong-explicit-pin',context,'baseline_sha256','f'*64,
                lambda:baseline.compare(reference,reports,context)))
        compatible.append(detail)
    result.update(saved_record_compatibility=compatible,saved_record_negative_checks=negatives,
                  saved_record_negative_check_count=len(negatives),passed=True)
    target=DRAFT/'draft-cpu-check-receipt.json'
    target.write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
    print(json.dumps(dict(passed=True,tests=tested.testsRun,saved_negative_checks=len(negatives),
        receipt=str(target),receipt_sha256=file_hash(target)),sort_keys=True))


if __name__=='__main__':
    with patch('subprocess.Popen',side_effect=AssertionError('No process execution')), \
         patch('subprocess.run',side_effect=AssertionError('No process execution')), \
         patch('socket.socket',side_effect=AssertionError('No socket execution')):
        check()
