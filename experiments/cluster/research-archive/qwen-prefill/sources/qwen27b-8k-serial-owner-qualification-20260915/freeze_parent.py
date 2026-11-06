"""Freeze the config-only serial parent; old binary pins are retained, not rehashed here."""
import json
from pathlib import Path
from assemble import BASE, pin


def write(name,value):
    with (BASE/name).open('x') as stream:
        json.dump(value,stream,sort_keys=True,indent=2);stream.write('\n')


def main():
    lineage=json.loads((BASE/'lineage.json').read_bytes());old=Path(lineage['previousParent']['path']).parent
    input_root=Path(lineage['preparedInputs']['path']).parent;audit=Path(lineage['comparator']['path']).parent
    oldpins={row['path']:row for row in json.loads((old/'run-pins.json').read_bytes())['files']}
    deployment=json.loads((BASE/'deployment.json').read_bytes())
    retained={}
    for rank in deployment['ranks']:
        for row in rank['files']:
            source=Path(row['source'])
            expected=dict(path=str(source),bytes=row['bytes'],sha256=row['sha256'])
            if not source.is_relative_to(BASE):
                assert oldpins[str(source)]==expected
                retained[str(source)]=expected
    for path,row in oldpins.items():
        if '/cluster-owner-diagnostic-drain-draft-20260915/local-bundle/' in path:retained[path]=row
    write('artifact-reuse.json',dict(schema='qwen27b_8k_unchanged_artifact_pins_v1',
        inheritedFrom=pin(old/'run-pins.json'),artifacts=list(retained.values()),
        actualArtifactRehashPerformed=False,rootCopyAndPreflightMustRehash=True))
    write('comparison-gates.json',dict(comparator=lineage['comparator'],sourceInputs=lineage['preparedInputs'],
        expectedAgreement=pin(BASE/'expected-agreement.json'),request=pin(BASE/'inputs/request.json'),
        metadata=pin(BASE/'provenance/recording-metadata.json'),prompt=pin(BASE/'inputs/prompt.ids.json'),
        requiredReference=dict(model='registered_qwen38_27b',promptCount=8192,chunkSize=512,outputCount=128,stageCut=16,
            requestID=lineage['requestID'],completedFrames=143,committedTokens=8319),
        successful8kReferenceAvailableAtFreeze=False,candidateOrReferenceOutputsRead=False,numericalComparisonPerformed=False))
    write('commands.json',dict(workingDirectory=str(BASE),rootOnlyRemoteAndNative=True,
        sourceCheck=['/usr/bin/python3','-B',str(BASE/'check_source.py'),'--artifacts'],
        sequentialCopy=[['/usr/bin/python3','-B',str(BASE/'deploy_copy_only.py'),'--rank',str(rank)] for rank in (0,1)],
        afterAuthorizedPurgeSequentialPreflight=[['/usr/bin/python3','-B',str(BASE/'preflight.py'),'--rank',str(rank)] for rank in (0,1)],
        physicalAfterMatchedReferenceAndRootGates=['/usr/bin/python3','-B',str(BASE/'run_physical.py')],
        validateCollectedReference=['/usr/bin/python3','-B',str(BASE/'verify_reference.py'),'--reference','ACTUAL_8K_REFERENCE_STDOUT',
            '--reference-sha256','ACTUAL_DECLARED_SHA256','--output',str(BASE/'reference-only-check.json')],
        noAutomaticRetry=True,compilerOrNativeRebuildRequired=False))
    paths={}
    for package in (old,input_root,audit):
        paths[str(package/'manifest.json')]=pin(package/'manifest.json')
        members=json.loads((package/'manifest.json').read_bytes())['files']
        members=[dict(path=name,**value) for name,value in members.items()] if type(members) is dict else members
        for row in members:
            path=package/row['path'];paths[str(path)]=pin(path)
    paths.update(retained)
    for path in BASE.rglob('*'):
        if path.is_file():paths[str(path)]=pin(path)
    write('run-pins.json',dict(schema='qwen27b_8k_serial_owner_run_pins_v1',files=[paths[key] for key in sorted(paths)]))
    files={}
    for path in sorted(BASE.rglob('*')):
        if path.is_file() and path.name!='manifest.json':
            value=pin(path);files[str(path.relative_to(BASE))]=dict(bytes=value['bytes'],sha256=value['sha256'])
    write('manifest.json',dict(schema='qwen27b_8k_serial_owner_qualification_v1',files=files,
        runtimeBehaviorChanged=False,compilerModelOrRemoteExecuted=False,artifactRehashDeferredToRoot=True,
        successful8kReferenceAvailableAtFreeze=False))
    print(json.dumps(dict(manifest=pin(BASE/'manifest.json'),members=len(files),runPins=pin(BASE/'run-pins.json'),runPinCount=len(paths))))


if __name__=='__main__':main()
