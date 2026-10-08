"""Declare exact raw 8K tokens and unchanged registered cut16 policy before execution."""
from pathlib import Path
import base64
import hashlib
import json
import sys

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
AUDIT = ROOT / 'qwen27b-cut16-numerical-audit-20260915'
AUDIT_SHA = 'f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe'
SHORT = ROOT / 'qwen27b-cut16-owner-qualification-20260915'
PROMPT_SOURCE = ROOT / 'qwen9b-balanced-prefill-candidate-20260915/inputs/prompt.ids.json'
PROMPT_SHA = 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def publish(path, value):
    raw = value if type(value) is bytes else (json.dumps(value, sort_keys=True, separators=(',', ':'))+'\n').encode()
    with path.open('xb') as stream:
        stream.write(raw)


def main():
    assert pin(AUDIT/'manifest.json')['sha256'] == AUDIT_SHA
    for member in json.loads((AUDIT/'manifest.json').read_bytes())['files']:
        actual = pin(AUDIT/member['path'])
        assert (actual['bytes'], actual['sha256']) == (member['bytes'], member['sha256'])
    sys.path.insert(0, str(AUDIT))
    from audit_scope import AuditScope, pinned_scope
    from audit_common import request_context
    from prepare_expected import expected
    ids = json.loads((BASE/'declared-identities.json').read_bytes())
    raw = PROMPT_SOURCE.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == PROMPT_SHA
    tokens = json.loads(raw)
    assert len(tokens) == 8192 and all(type(x) is int and 0 <= x < 248320 for x in tokens)
    metadata_raw = (SHORT/'provenance/recording-metadata.json').read_bytes()
    assert hashlib.sha256(metadata_raw).hexdigest() == '4c22d847bb83991a37d83a9c97be94eb8152f5341c8deaa4b3bf6e677eb6eeeb'
    context = request_context(raw, ids['requestID'], AuditScope('registered_qwen38_27b',8192,512,128,16))
    old = json.loads((SHORT/'inputs/request.json').read_bytes())
    request = {name:old[name] for name in ('model','artifactSHA256','configurationSHA256','manifestSHA256')}
    request.update(requestID=ids['requestID'],promptCount=8192,chunkSize=512,outputCount=128,stageCut=16,
        stopTokenIDs=[],mtp=False,promptFileSHA256=PROMPT_SHA,promptTokenIDsSHA256=context['prompt_tokens_sha'],
        selection='Exact existing 9B benchmark raw token-ID file reused as a diagnostic 27B input; no new tokenization',
        sourcePrompt=pin(PROMPT_SOURCE),chatTemplateApplied=False,modelOrSwiftTokenizerExecuted=False,
        performanceWorkloadQualified=False)
    publish(BASE/'inputs/prompt.ids.json', raw)
    publish(BASE/'inputs/request.json',request)
    publish(BASE/'provenance/recording-metadata.json',metadata_raw)
    publish(BASE/'provenance/registered_profiles.json',(AUDIT/'registered_profiles.json').read_bytes())
    source_identity = (SHORT/'provenance/expected-identity.json').read_bytes()
    publish(BASE/'provenance/expected-identity.json', source_identity)
    identity=json.loads(source_identity)
    value=expected((BASE/'inputs/request.json').read_bytes(), metadata_raw, raw,
        ids['membershipEpoch'],identity['storageCommitmentSHA256'],identity['arithmeticSHA256'])
    publish(BASE/'expected-agreement.json',value)
    controller=json.loads((SHORT/'configuration/controller.json').read_bytes())
    controller.update(requestID=ids['requestID'],membershipEpoch=ids['membershipEpoch'],
                      promptTokenIDs=tokens,chunkSize=512,expectedTokenIDs=None)
    publish(BASE/'configuration/serial-correctness-controller.json',controller)
    for rank in (0,1):
        # Exact existing installed owner settings; no installation is performed.
        publish(BASE/('configuration/owner-rank'+str(rank)+'.json'),(SHORT/('configuration/owner-rank'+str(rank)+'.json')).read_bytes())
    oldjob=json.loads((ROOT/'qwen27b-cut16-full-reference-20260915/package/example-job.json').read_bytes())
    job=dict(oldjob,request_id=ids['requestID'],prompt_count=8192,chunk_size=512,prompt_sha256=PROMPT_SHA,
        prompt_file='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/inputs/27b-8k-prompt.ids.json',
        run_dir='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/long-27b-cut16-1')
    publish(BASE/'reference-job.json',job)
    scope=pinned_scope(request,json.loads(metadata_raw));assert scope.frames==143 and scope.frontier==8319
    for path in [BASE/'configuration/serial-correctness-controller.json'] + [BASE/('configuration/owner-rank'+str(i)+'.json') for i in (0,1)]:
        encoded=path.read_bytes();assert encoded.endswith(b'\n') and encoded.count(b'\n')==1
        outer=json.loads(encoded);ready=base64.b64decode(outer['readyTemplateBase64'],validate=True)
        assert ready.endswith(b'\n') and ready.count(b'\n')==1
    publish(BASE/'provenance/prepare-receipt.json',dict(comparatorManifest=pin(AUDIT/'manifest.json'),
        preparer=pin(AUDIT/'prepare_expected.py'),catalog=pin(AUDIT/'registered_profiles.json'),
        prospectiveAgreement=pin(BASE/'expected-agreement.json'),request=pin(BASE/'inputs/request.json'),
        prompt=pin(BASE/'inputs/prompt.ids.json'),metadata=pin(BASE/'provenance/recording-metadata.json'),
        frames=143,frontier=8319,stateEntryCounts=[36,108],nativeCompilerModelOrRemoteExecuted=False,
        actualCandidateOrReferenceOutputsRead=False,catalogOrComparatorRuntimeChanged=False))
    print(json.dumps(dict(requestID=ids['requestID'],membershipEpoch=ids['membershipEpoch'],
        request=pin(BASE/'inputs/request.json'),agreement=pin(BASE/'expected-agreement.json'),referenceJob=pin(BASE/'reference-job.json'))))


if __name__=='__main__':
    main()
