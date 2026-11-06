#!/usr/bin/env python3
"""Bounded source/patch checks only. Does not compile, execute or load Swift."""
import copy, hashlib, json, re
from pathlib import Path
D=Path(__file__).resolve().parent
R=Path('/Users/developer/DarkbloomDev/d-inference')
S=R/'experiments/cluster/inference/Sources/ClusterInference'
def digest(b): return hashlib.sha256(b).hexdigest()
checks = 0
def require(test, message):
    global checks
    checks += 1
    if not test: raise AssertionError(message)
def code(s):
    s=re.sub(r'//[^\n]*','',s)
    return s

def validate(files):
    old={n:(D/'originals'/n).read_text() for n in ['VerifiedCheckpoint.swift','PreparedQwenCheckpoint.swift','PreparedQwenLayerSource.swift']}
    checkpoint=files['proposed/PreparedQwenCheckpoint.swift']
    tail='        let descriptors = try tensorDescriptors(checkpoint: checkpoint)'
    require(checkpoint[checkpoint.index(tail):] == old['PreparedQwenCheckpoint.swift'][old['PreparedQwenCheckpoint.swift'].index(tail):], 'canonicalization/quantization tail changed')
    require(checkpoint.count('VerifiedCheckpoint(directory:') == 1, 'checkpoint full verification duplicated')
    guard='try checkpoint.requireConfiguration(originalConfiguration)'
    require(checkpoint.index(guard)<checkpoint.index(tail) and 'try checkpoint.checkUnchanged()' in checkpoint[:checkpoint.index(tail)], 'configuration reuse/check precedes descriptors')
    source=files['proposed/PreparedQwenLayerSource.swift']
    start='        let bytes = validated.sourceBytes, largest = validated.largestSourceBytes'
    end='\n    }\n    // Neither descriptor'
    prior=old['PreparedQwenLayerSource.swift'];body=prior[prior.index(start):prior.index(end)]
    adjusted='\n'.join(x[4:] for x in body.splitlines())
    require(adjusted in source, 'shared source assembly changed beyond indentation')
    require('maximumPayloadBytes: LocalCorrectnessStorage.maximumManifestPayloadBytes' in source and 'validateLegacy(' in source, 'legacy stage limits removed')
    require('validateRegistered(' not in source, 'registered path leaked into legacy stage wrapper')
    old_verified=old['VerifiedCheckpoint.swift'];new=files['proposed/VerifiedCheckpoint.swift']
    for fragment in ['file.digest()', 'maximumPayloadBytes, payloadBytes > maximumPayloadBytes', 'let matchedManifest = try QwenCheckpointManifestPin.match', 'self.verifiedManifestSHA256 = matchedManifest']:
        require(new.count(fragment)==old_verified.count(fragment), 'verification guard/loop altered')
    require(new.index('self.configurationSHA256 = configurationSHA256')>new.index('Checkpoint aggregate mismatch'), 'verified config property before file verification')
    require('sha256(data) == configurationSHA256' in new, 'reuse configuration not bound')
    core='\n'.join(code(v) for k,v in files.items() if k.startswith('QwenDenseConstructor') and k.endswith('.swift') and k != 'QwenDenseConstructorEntry.swift')
    for denied in [r'\beval\s*\(', r'\.read\s*\(', r'loadVerifiedQwen', r'recurrentPrefill\s*\(', r'CBv2OwnedRequest', r'\.asArray\s*\(', r'\.item\s*\(']:
        require(re.search(denied,core) is None,'probe reaches tensor values/materializer/request')
    source_probe=files['QwenDenseConstructorSource.swift']
    require('canonicalTensors: observed.map(\\.canonical)' in source_probe and 'profile.model == admission.specification.model' in source_probe, 'actual observed inventory does not bind selected profile')
    require('validateRegistered(observed,' in source_probe, 'registered actual descriptor validation absent')
    require('observeQwenDenseConstructor' in source_probe and 'withRandomState(MLXRandom.RandomState(seed: 7))' in source_probe, 'full actual constructor/scoped random missing')
    stages=files['QwenDenseConstructorStages.swift']
    require('prepareQwenLayerStageModel' in stages and 'validateObservedQwenDenseStage' in stages, 'actual compact validation bypassed')
    require(stages.index('guard retired == nil else { throw') < stages.index('result.append(observation)'), 'compact publish before release gate')
    producer=files['QwenDenseConstructorProbe.swift']
    require(producer.index('VerifiedCheckpoint(directory:')<producer.index('prepareQwenDenseConstructorSource('), 'constructor precedes full verification')
    require(producer.count('VerifiedCheckpoint(directory:')==1, 'probe verification count changed')
    require('do { try nativeError.check() }' in producer and 'accompanying Swift failure' in producer, 'native secondary-error precedence lost')
    require(producer.index('guard retiredFiles == nil')<producer.index('return result\n            } catch'), 'file release does not gate success')
    entry=files['QwenDenseConstructorEntry.swift'];parser=files['QwenDenseConstructorCLI.swift']
    require(entry.index('alarm(UInt32(timeoutSeconds))')<entry.index('let admission = try')<entry.index('runQwenDenseConstructorProbe('), 'early branch deadline/admission ordering')
    require('defer { alarm(0) }' in entry and 'now - start < limit' in entry, 'early branch deadline absent')
    require('arguments[$0] == "--mode" && arguments[$0 + 1] == mode' in parser, 'mode detection intercepts an unrelated value')
    require('arguments.count == 8' in parser and 'Set(values.keys) == allowed' in parser and 'values[key] == nil' in parser, 'closed arguments not exact')
    require('(1...300).contains(timeout)' in parser and 'String(timeout) == rawTimeout' in parser, 'timeout grammar widened')
    require('try emitJSON(result)' in entry and entry.index('try checked()\n        try emitJSON(result)')>entry.index('runQwenDenseConstructorProbe('), 'report emitted before success/deadline')
    types=files['QwenDenseConstructorTypes.swift']
    require('import MLX' not in types and 'MLXArray' not in types, 'CPU DTO/native allocation flag changed')
    for fragment in ['nativeAllocationFree = false','actualLoadedInventoryEstablished = false','numericalParityEstablished = false','providerEligibilityEstablished = false','independentResourceAdmissionEstablished = false','sourceTensorPayloadsMaterialized = false','forwardExecuted = false','logicalBytesAreAllocationMeasurement = false']:
        require(fragment in types, 'evidence scope flag lost: '+fragment)
    require('expectedPostLoadSummary' in types and 'constructorDType' in types, 'actual/predicted dtype records merged')

def run():
    files={str(p.relative_to(D)):p.read_text() for p in D.glob('QwenDenseConstructor*.swift')}
    files.update({str(p.relative_to(D)):p.read_text() for p in (D/'proposed').glob('*.swift')})
    validate(files)
    baseline_checks = checks
    mutations=[('proposed/PreparedQwenCheckpoint.swift','try checkpoint.requireConfiguration(originalConfiguration)','try checkpoint.checkUnchanged()'),
      ('proposed/PreparedQwenLayerSource.swift','maximumPayloadBytes: LocalCorrectnessStorage.maximumManifestPayloadBytes','maximumPayloadBytes: nil'),
      ('QwenDenseConstructorSource.swift','canonicalTensors: observed.map(\\.canonical)','canonicalTensors: []'),
      ('QwenDenseConstructorProbe.swift','do { try nativeError.check() }','do { try check() }'),
      ('QwenDenseConstructorEntry.swift','alarm(UInt32(timeoutSeconds))','alarm(0)'),
      ('QwenDenseConstructorCLI.swift','(1...300).contains(timeout)','(1...3000).contains(timeout)'),
      ('QwenDenseConstructorTypes.swift','nativeAllocationFree = false','nativeAllocationFree = true'),
      ('QwenDenseConstructorStages.swift','try validateObservedQwenDenseStage','try skippedStageValidation')]
    rejected=[]
    for name,a,b in mutations:
        changed=dict(files);require(a in changed[name], 'mutation target missing');changed[name]=changed[name].replace(a,b,1)
        try: validate(changed)
        except (AssertionError, ValueError): rejected.append(name+': '+a)
        else: raise AssertionError('mutation not rejected: '+name)
    pins=[]
    for listname in ['fixture-source-list.json','source-dependencies.json']:
        data=json.loads((D/listname).read_text())
        for p in data['sources']+([data['stdin']] if 'stdin' in data else []):
            raw=Path(p['path']).read_bytes();require(digest(raw)==p['sha256'] and len(raw)==p['bytes'],'input pin drift: '+p['path']);pins.append(p)
    for p in (D/'originals').glob('*.swift'): require(p.read_bytes()==(S/p.name).read_bytes(),'legacy source base changed')
    return {'schemaVersion':1,'status':'passed','sourceInvariantChecks':baseline_checks,'mutationRejections':len(rejected),
      'rejectedSourceMutations':rejected,'fixtureExpectedAccepted':11,'fixtureExpectedRejected':41,
      'swiftCompiledOrExecuted':False,'nativeOrModelPayloadAccess':False,'syntheticCheckpointFixtureExecuted':False,
      'runtimeClaim':'source review only; root must compile and independently gate actual constructor probe',
      'checkedInputPins':len(pins),'sourceFiles':{k:digest(v.encode()) for k,v in sorted(files.items())}}
if __name__=='__main__':
    print(json.dumps(run(),indent=2,sort_keys=True))
