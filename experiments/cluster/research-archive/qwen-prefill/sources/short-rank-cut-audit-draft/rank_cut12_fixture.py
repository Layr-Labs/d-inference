"""Invented rank containers around an already qualified one-process baseline.

No real rank cutpoint or completion evidence is supplied by these CPU fixtures.
Native arrays are never created; boundary hashes and allocator values are fake.
"""
import copy
import json
from pathlib import Path

import audit_rank_cut12 as adapter

ROOT = Path(__file__).resolve().parent.parent
REFERENCE = ROOT / 'runs/qwen-layer-stage-cut12-peer24-20260914/native/stdout.jsonl'
PROMPT = ROOT / 'runs/qwen-layer-stage-cut12-peer24-20260914/remote-metadata/prompt.final.json'
TEACHER = ROOT / 'runs/qwen-layer-stage-cut12-peer24-20260914/remote-metadata/teacher.final.json'
EPOCH = '93bf315186ac40928137a92cd50e73da'


def fixture():
    audit = adapter.core()
    baseline, pin = audit.read_rows(REFERENCE)
    assert pin == audit.BASELINE_STDOUT_SHA
    expected_raw = adapter.bounded(adapter.EXPECTED_PATH, 2 * 1024**2)
    assert adapter.digest(expected_raw) == adapter.EXPECTED_SHA256
    expected = json.loads(expected_raw)
    old = baseline[0]['baseline']
    request, simple, _ = audit.fresh_request(old['request'], EPOCH)
    rows = []
    for rank in range(2):
        common = dict(schemaVersion=1,epoch=EPOCH,rank=rank,worldSize=2,transport='loopback-test',backend='ring')
        load = copy.deepcopy(baseline[1]['stageLoads'][rank])
        start,end = [(0,12),(12,32)][rank]
        frames = []
        for index, old_frame in enumerate(old['frames']):
            step = request['steps'][index]; frame=step['frame']; tokens=old_frame['committedTokens']
            entries=copy.deepcopy([entry for entry in old_frame['state']['entries'] if start<=entry['globalLayerIndex']<end])
            has_logits = rank == 1 and index >= 2
            shape=[1,frame['tokenCount'],4096]
            fake_payload = audit.digest(('CPU fixture only boundary '+str(index)).encode())
            capture=dict(kind='qwen_layer_stage_rank_frame_capture',
                identity=audit.session_identity(load,rank,simple), frame=copy.deepcopy(frame),committedTokens=tokens,
                sourceLayerStart=start,sourceLayerEnd=end,stateEntries=entries,
                logicalStateBytes=sum(x['byteCount'] for x in entries),stageStateSHA256=audit.state_hash(entries,tokens),
                boundaryPayloadSHA256=fake_payload,boundaryShape=shape,boundaryDType='bfloat16',
                outputKind='hidden' if rank==0 else ('logits' if has_logits else 'evaluation_handle'),
                outputShape=shape if rank==0 else ([1,248320] if has_logits else [1,1]),outputDType='bfloat16')
            if has_logits: capture['logits']=copy.deepcopy(old_frame['logits'])
            header=audit.header_bytes(baseline[1]['stageLoads'][0],simple,step,fake_payload)
            frames.append(dict(kind='qwen_layer_stage_rank_frame_completion',capture=capture,
                headerSHA256=audit.digest(header),completedTransportPhase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed'))
        memory=[dict(phase=phase,activeMLXBytes=1,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=1)
            for phase in ('before_stage_load','stage_loaded_request_admitted','stage_request_retired_weights_resident','stage_model_released_cache_cleared')]
        report=dict(kind='qwen_layer_stage_rank_report',**common,completed=True,correctnessOnly=True,
            throughputMeasurementValid=False,modelForwardCompared=False,physicalTransferQualified=False,
            sourceLoad=load,request=copy.deepcopy(request),frames=frames,allRequestStateRetired=True,
            modelReleased=True,conservativeStateAndBoundaryBytes=baseline[1]['conservativeStateAndBoundaryBytes'],memory=memory)
        rows.append([dict(kind='qwen_layer_stage_rank_ready',**common),report])
    return audit,baseline,expected,rows
