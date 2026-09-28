"""stage_p2p_check v1: fixed no-model fixture namespace, separate from stage ranks."""
from .common import envelope,exact,flags,require,sha
READY='stage_p2p_ready'
TERMINAL='stage_p2p_check'
MAX_STDOUT=4*1024**2
MAX_LINE=2*1024**2


def validate(record,rank,epoch,context):
    kind=record.get('kind');require(kind in(READY,TERMINAL),'Wrong P2P evidence namespace')
    envelope(record,kind,rank,epoch)
    if kind==READY:return
    flags(record,passed=True,correctnessOnly=True,throughputMeasurementValid=False,modelForwardCompared=False,physicalTransferQualified=False)
    sha(record['fixtureFingerprint'])
    expected=[f'{dtype}-h{hidden}' for dtype in('float32','float16','bfloat16') for hidden in(128,4096,8192)]
    cases=record['cases'];require(isinstance(cases,list) and [x['caseID'] for x in cases]==expected,'Wrong fixed P2P fixture cases')
    require(len(record['controlCases'])==7,'Wrong fixed control coverage')
    for case in cases:
        require(case['complete']is True and len(case['frames'])==6,'Incomplete P2P frame coverage')
        for frame in case['frames']:
            sha(frame['payloadSHA256']);sha(frame['headerSHA256']);require(frame['nativeBytesExact']is True,'Native byte comparison failed')


def pair(records,context):
    a,b=records
    for key in ('fixtureFingerprint','controlCases','cases'):exact(a[key],b[key],'Peer P2P evidence differs: '+key)
    return dict(namespace=TERMINAL,schema_version=1,residuals_per_rank=54,controls_per_rank=7,
                native_assertions_passed=True,independent_payload_fixture_oracle=False,baseline_compared=False)
