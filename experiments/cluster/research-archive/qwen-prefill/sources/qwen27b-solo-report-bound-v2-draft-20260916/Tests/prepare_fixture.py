"""Retained CPU metadata -> serialization cases, never a successful solo receipt.

The Swift fixture uses exact stored-field declarations and the real encoder.
Only native constructors/methods are omitted, and Decodable is added in this
test file so retained JSON can populate those fields without device access.
"""
import copy
import hashlib
import json
from pathlib import Path
import sys
import uuid

BASE = Path(__file__).resolve().parent.parent
ROOT = BASE.parent
OLD = ROOT / 'qwen27b-matched-short-cohort-draft-20260916'
WORK = OLD / 'workspace'
SWIFT = WORK / 'experiments/cluster/inference/Sources/ClusterInference'
FAILED = OLD / 'physical-source/run-1/returned'
REFERENCE = ROOT / 'qwen27b-8k-full-reference-20260915/physical-collect-1/returned/native/worker-0.stdout'
sys.path.insert(0, str(BASE / 'run-template'))
from binding_common import canonical
from reference_contract import expected_identity


def sha(data):
    return hashlib.sha256(data).hexdigest()


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index+1]
    raise ValueError('Unclosed source declaration: ' + marker)


def prepare():
    out = BASE / 'Tests/generated'
    out.mkdir(mode=0o700)
    sources = {}
    def read(path, expected=None):
        raw = path.read_bytes()
        if expected is not None and sha(raw) != expected:
            raise ValueError('Retained source changed: ' + str(path))
        sources[str(path)] = dict(bytes=len(raw), sha256=sha(raw))
        return raw
    raw = read(REFERENCE, '1922793ab2f252d52b3729efd4222220935bd1d046c6649fc71afded1ad70305')
    full = json.loads(raw.splitlines()[1])
    progress = [json.loads(line) for line in read(FAILED/'native/worker-0.stdout',
        '9cc19f5b8b13dcf767010fadb75501cb882b7d8d3a209b0ac946c664d5f3f56a').splitlines()]
    assert len(progress) == 4 and len(full['resources']['budget']['sourceNames']) == 1847
    job = json.loads(read(FAILED/'job.json'))
    tokens = json.loads(read(FAILED/'prompt.json'))
    expected = json.loads(read(FAILED/'expected.json'))
    cases = []
    for measured in (1, 2, 3):
        first, model = copy.deepcopy(progress[:2])
        case_job = dict(job, measured_count=measured)
        first['measuredCount'] = model['measuredCount'] = measured
        first['requestIDs'] = [first['requestIDs'][0]] + [str(uuid.UUID(int=i)).upper() for i in range(31,31+measured)]
        first['requestFingerprints'] = [expected_identity(dict(case_job, request_id=i.lower()), tokens)['requestFingerprint']
            for i in first['requestIDs']]
        rows = []
        for index in range(measured+1):
            row = copy.deepcopy(progress[2])
            row['measuredCount'] = measured
            row['request'].update(ordinal=index, isWarmup=index==0)
            execution = row['request']['execution']
            execution.update(requestID=first['requestIDs'][index], requestFingerprint=first['requestFingerprints'][index])
            # Wide UInt64 timestamps exercise encoding width, not elapsed performance.
            start = 2**64 - 30_000_000_000 + index * 3_000_000_000
            stamps = [start + 1_000_000_000 + i * 1_000_000 for i in range(128)]
            end = stamps[-1] + 1_000_000
            execution['timing'].update(requestStartNanoseconds=start, selectedTokenNanoseconds=stamps,
                retiredNanoseconds=end, prefillSeconds=1, decodeSeconds=.127,
                prefillTokensPerSecond=8192, decodeTokensPerSecond=1000)
            row['publishedNanoseconds'] = end+1
            rows.append(row)
        model['publishedNanoseconds'] = rows[0]['request']['execution']['timing']['requestStartNanoseconds']-1
        resources = copy.deepcopy(full['resources'])
        resources['budget']['requestFingerprint'] = first['requestFingerprints'][0]
        # Every actual tensor name/byte count/allocator bound is retained exactly.
        runtime = copy.deepcopy(full['runtime'])
        runtime.update(processID=1, mainBundlePath=job['deployment'], mainBundleResourcePath=job['deployment'],
            executablePath=job['deployment']+'/cluster-inference', mainBundleName='native', executableName='cluster-inference')
        memory = [dict(phase='fabricated_cpu_serialization_'+str(i), activeMLXBytes=2**63-1,
            cachedMLXBytes=0, peakMLXBytesSinceProcessStart=2**63-1) for i in range(4+measured)]
        final = dict(kind='qwen_resident_solo_generation_report', schemaVersion=1, completed=True,
            verifiedFullModelLoads=1, warmupCount=1, measuredCount=measured, freshRequestsAdmitted=1+measured,
            modelReleased=True, allRequestStateRetired=True, prefixReuse=False, mtpEnabled=False,
            allocatorPolicy='disable_freed_buffer_cache_v1', unusedDiagnosticAllowanceStillReserved=True,
            independentNumericalComparisonPerformed=False, physicalOrPerformanceQualificationEstablished=False,
            externalTTFTMeasured=False, source=model['source'], sourceLoad=model['sourceLoad'],
            expectedTokenFileSHA256=job['expected_sha256'], kernelEligibility=rows[0]['kernelEligibility'],
            requests=[r['request'] for r in rows], resources=resources, memory=memory, runtime=runtime)
        cases.append(dict(measured=measured, job=case_job, first=first, model=model, rows=rows, final=final))
    fixture = dict(schema='fabricated_solo_report_encoding_cases_v1', tokens=tokens, expected=expected, cases=cases,
        actualSoloFinalReport=False, actualPerformanceEvidence=False)
    (out/'cases.json').write_bytes(canonical(fixture)+b'\n')
    specs = [
        ('QwenResidentSoloCohort.swift','QwenResidentSoloKernelEligibility'),
        ('QwenResidentSoloCohort.swift','QwenResidentSoloCohortRequest'),
        ('QwenResidentSoloCohort.swift','QwenResidentSoloCohortReport'),
        ('QwenResidentSoloTiming.swift','QwenResidentSoloTiming'),
        ('QwenResidentSoloTiming.swift','QwenResidentSoloRequestResult'),
        ('QwenLongPrefillReferenceEvidence.swift','QwenLongPrefillReferenceSource'),
        ('VerifiedQwenDiagnosticLoading.swift','VerifiedQwenDiagnosticReceipt'),
        ('QwenFullGenerationReferenceResources.swift','QwenFullGenerationReferenceResourceReceipt'),
        ('QwenFullGenerationReferenceBudget.swift','QwenFullGenerationReferenceBudget'),
        ('QwenLayerStageComparison.swift','QwenStageMemoryObservation'),
        ('QwenDenseStageLoadResources.swift','QwenDenseStageLoadRuntimeObservation'),
        ('../../../../../libs/mlx-swift-lm/Libraries/MLXLLM/Models/QwenResidentBenchmarkObservation.swift',
            'QwenGatedDeltaWarmupObservation'),
    ]
    # Resolve the one dependency source explicitly; no unrelated source-tree scan.
    specs[-1] = (str(WORK/'libs/mlx-swift-lm/Libraries/MLXLLM/Models/QwenResidentBenchmarkObservation.swift'), specs[-1][1])
    pieces = ['import Foundation\n']
    extracted = []
    for filename, name in specs:
        path = Path(filename) if Path(filename).is_absolute() else SWIFT/filename
        text = read(path).decode()
        declaration = block(text, ('public ' if name=='QwenGatedDeltaWarmupObservation' else '')+'struct '+name+':')
        stops = [declaration.index(mark) for mark in ('\n    init(', '\n    static func ', '\n    func ')
                 if mark in declaration]
        fields = declaration[:min(stops)].rstrip()+'\n}' if stops else declaration
        decoded = fields.replace(': Encodable {', ': Encodable, Decodable {', 1)
        pieces.append(decoded)
        extracted.append(dict(type=name, source=str(path), fullDeclarationSHA256=sha(declaration.encode()),
            exactStoredDeclarationSHA256=sha(fields.encode()), generatedSHA256=sha(decoded.encode()),
            nativeMethodsOmitted=bool(stops), testOnlyDecodableAdded=decoded!=fields))
    pieces.append(block(read(SWIFT/'Options.swift').decode(), 'struct ProbeError:'))
    pieces.append(read(SWIFT/'CanonicalJSON.swift').decode().replace('import Foundation\n','',1))
    entry = BASE/'proposed/experiments/cluster/inference/Sources/ClusterInference/QwenResidentSoloEntry.swift'
    encoder = block(read(entry).decode(), 'enum QwenResidentSoloOutput {')
    pieces.append(encoder)
    scratch = full['resources']['budget']['payloadReadScratchBytes']
    assert scratch == 8404992
    pieces.append('enum CheckpointAlignedReadPlan { static let maximumScratchAllocationBytes = '+str(scratch)+' }')
    dto = '\n\n'.join(pieces)+'\n'
    assert 'import MLX' not in dto and 'GPU.' not in dto and 'Memory.' not in dto
    (out/'ExactDTOs.swift').write_text(dto)
    receipt = dict(schema='solo_encoding_fixture_preparation_v1', sources=sources, declarations=extracted,
        realBoundedEncoderSHA256=sha(encoder.encode()), exactDTOsSHA256=sha(dto.encode()),
        casesSHA256=sha((out/'cases.json').read_bytes()), sourceBudgetBytes=len(canonical(full['resources']['budget'])),
        sourceReceiptBytes=len(canonical(full['resources'])),
        provisionalPythonReportBytes=[len(canonical(c['final'])) for c in cases],
        actualSoloFinalReport=False, swiftExecuted=False, modelOrKernelExecuted=False)
    (out/'preparation.json').write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n')
    print(json.dumps({k:receipt[k] for k in ('sourceBudgetBytes','sourceReceiptBytes','provisionalPythonReportBytes')}))


if __name__ == '__main__':
    prepare()
