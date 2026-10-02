"""Closed success DTO and independently derived synthetic request identities."""
import hashlib
import json
import uuid
from pathlib import Path
from readiness_config import pin, require
from readiness_stream import WARNING, MISMATCH
from prefill_compute_archive import digest

PROFILE = 'long_prefill_8k_v1'
PROFILE_SHA = '2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b'
CONFIG_SHA = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
ARTIFACT_SHA = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def exact(actual, expected, message):
    require(type(actual) is type(expected) and actual == expected, message)


def entries(epoch, warmups=1):
    values = []
    for ordinal in range(3):
        current = epoch if ordinal == 0 else sha(
            ('qwen-cohort-readiness-fixture-request-v1|' + epoch + '|' + str(ordinal)).encode())[:32]
        request_id = str(uuid.UUID(hex=current))
        tokens = [(i * 17 + (1 if ordinal == 1 else 0)) % 1024 for i in range(8192)]
        request_sha = sha('\n'.join(['qwen-stage-profiled-prefill-request-v1', PROFILE,
            PROFILE_SHA, request_id, 'batch=1', 'prompt=8192', 'chunk=512', 'output=1']).encode())
        recorded = sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1',
            PROFILE, PROFILE_SHA, request_sha, 'vocabulary=248320',
            'prompt=' + ','.join(map(str, tokens)), 'teacher=']).encode())
        values.append(dict(ordinal=ordinal, epoch=current, requestID=request_id,
            recordedRequestFingerprint=recorded, promptFileSHA256=sha(canonical(tokens)),
            excludedWarmup=ordinal < warmups))
    require(len({x['epoch'] for x in values}) == 3, 'Derived fixture epochs collided')
    return values


def validate_record(record, rank, epoch, scenario):
    pin(epoch, 32)
    fixed = dict(kind='qwen_long_prefill_cohort_readiness_check', schemaVersion=1,
        epoch=epoch, fixtureCase='warmup-mismatch' if scenario == 'warmup-mismatch' else 'match',
        rank=rank, worldSize=2, transport='loopback-test',
        postAgreementMarker='reached_without_model_load', readinessExchangePassed=True,
        modelConstructed=False, weightsMaterialized=False, requestsExecuted=False,
        modelPayloadRead=False, requestStateCreated=False, arithmeticEnvironmentIsFixture=True,
        actualArtifactVerificationPerformed=False, actualOSResourceAdmissionPerformed=False,
        residentReuseQualified=False, physicalTransferQualified=False, throughputMeasurementValid=False)
    require(type(record) is dict and set(record) == set(fixed) | {'cohortAgreement', 'cohortReadiness'},
            'Unexpected readiness success record fields')
    for key, expected in fixed.items():
        exact(record[key], expected, 'Readiness identity/qualification differs: ' + key)
    descriptor = record['cohortAgreement']
    expected = dict(schemaVersion=1, kind='qwen_long_prefill_resident_cohort_agreement',
        initialEpoch=epoch, sourceConfigurationSHA256=CONFIG_SHA,
        expectedArtifactAggregateSHA256=ARTIFACT_SHA, profile=PROFILE, profileFingerprint=PROFILE_SHA,
        schedulingPolicy='serial_v1', logitsDType='bfloat16', transport='loopback-test',
        executionPath='cbv2-contiguous', requestCount=3,
        warmupCount=0 if scenario == 'warmup-mismatch' and rank == 1 else 1,
        tracePathsDisabled=True)
    hashes = {'planFingerprint', 'arithmeticEnvironmentSHA256', 'resourceAdmissionSHA256'}
    require(type(descriptor) is dict and set(descriptor) == set(expected) | hashes | {'requests'},
            'Unexpected cohort descriptor fields')
    for key, value in expected.items():
        exact(descriptor[key], value, 'Cohort descriptor differs: ' + key)
    for key in hashes:
        pin(descriptor[key])
    # Nested values need strict types too: Python considers True == 1.
    require(canonical(descriptor['requests']) == canonical(entries(epoch, expected['warmupCount'])),
            'Ordered fixture UUID/raw/full-history/warmup identities differ')
    raw = canonical(descriptor)
    require(len(raw) <= 16384, 'Cohort descriptor exceeded its native bound')
    fingerprint = sha(b'qwen-long-prefill-resident-cohort-v1|' + raw)
    readiness = dict(cohortAgreementFingerprint=fingerprint,
        readinessMaterialSHA256=sha(('qwen-long-prefill-resident-cohort-readiness-v1|' + fingerprint).encode()))
    require(record['cohortReadiness'] == readiness, 'Cohort/readiness digest recipe differs')


def validate_pair(streams):
    require(len(streams) == 2 and all(x.record is not None for x in streams), 'Both success records required')
    first, second = (x.record for x in streams)
    require(first['cohortAgreement'] == second['cohortAgreement'] and
            first['cohortReadiness'] == second['cohortReadiness'], 'Peers disagree on cohort intent')
    return dict(success_records=2, ordered_fixture_history_and_hashes_verified=True,
        native_admitted_plan_arithmetic_resource_metadata_source_bound=True,
        model_payload_or_numeric_audit_performed=False,
        cohort_fingerprint=first['cohortReadiness']['cohortAgreementFingerprint'])


def source_contract(output):
    source = Path(output) / 'source/experiments/cluster/inference/Sources/ClusterInference'
    names = ['Collective.swift', 'Options.swift', 'Main.swift',
        'QwenLongPrefillResidentCohortReadiness.swift', 'QwenLongPrefillCohortReadinessAdmission.swift',
        'QwenLongPrefillCohortReadinessCheck.swift', 'QwenLongPrefillResidentCohortAgreement.swift',
        'QwenLongPrefillResidentRankFixture.swift', 'QwenLayerStageProfiledPrefillRequestSpec.swift',
        'QwenLayerStageProfiledPrefillRecordedRequest.swift', 'QwenLongPrefillReadinessExchange.swift']
    text = {name: (source / name).read_text() for name in names}
    exchange_pin = 'a075b13f8606dcccd9459ba8140559af4d9d696bf9621c1b2d92838f333e210d'
    require(digest(source / 'QwenLongPrefillReadinessExchange.swift') == exchange_pin,
            'Readiness exchange must complete both ordered transfers before comparing')
    worker = Path(output) / 'source/experiments/cluster/runtime/rank_worker.py'
    require(digest(worker) == '2dbb639e3e112198f9a15cfeb98b21209657651e2126f6d59d7819202d55f5e3',
            'Readiness worker must suppress bundle import bytecode')
    literal = 'log("' + WARNING.decode().rstrip('\n') + '")' 
    require('if transport == .loopbackTest {\n            ' + literal in text['Collective.swift'],
            'Loopback warning source changed')
    require('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}'
            in text['Options.swift'], 'Warning logger encoding changed')
    require(MISMATCH.decode().split(': ', 1)[1].rstrip('\n') in text['QwenLongPrefillResidentCohortReadiness.swift'],
            'Cohort mismatch source changed')
    require('catch { log("cluster-inference: \\(error)"); exit(1) }' in text['Main.swift'],
            'Main diagnostic rendering changed')
    require(CONFIG_SHA in text['QwenLongPrefillResidentRankFixture.swift'] and
            ARTIFACT_SHA in text['QwenLongPrefillResidentRankFixture.swift'], 'Retained fixture pins changed')
    return dict(exact_warning_utf8=WARNING.decode(), exact_mismatch_utf8=MISMATCH.decode(),
        complete_before_compare_exchange_sha256=exchange_pin, bytecode_suppressed_worker_sha256=digest(worker),
        source_sha256={name: digest(source / name) for name in names},
        plan_arithmetic_resource_fingerprints_independently_derived=False)
