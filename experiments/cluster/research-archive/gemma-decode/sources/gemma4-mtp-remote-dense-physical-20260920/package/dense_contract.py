"""Closed target-only dense policy; no broader numerical/serving authority."""
from binding_common import require

POLICY='gemma4_verification_packed_m1_dense_serial_head_v1'
EMBEDDING_SHA256='45259723b22ef7d5c039213763eb57a0711bdc7e897ca112b58821b3d97827a4'
SUMMARY=dict(policy=POLICY,expectedDenseModules=235,expectedTiedHeads=1,
    serialHeadLogicalBytes=4*1048576,gatheredOverrideEnabled=False,
    singleRowOverrideEnabled=False,wholeModelNumericsQualified=False)

def target_summary(value):
    require(isinstance(value,dict) and set(value)==set(SUMMARY)
        and all(type(value[k]) is type(v) for k,v in SUMMARY.items()) and value==SUMMARY,
        'Exact dense target projection summary')

def target_terms(rows):
    require(len(rows)==34 and len({x['name'] for x in rows})==34,'Dense target must retain all34 distinct base terms')
    heads=[x for x in rows if x['name'].startswith('serialTargetHead:')]
    require([x['name'] for x in heads]==['serialTargetHead:row'+str(i) for i in range(4)],'Four independently charged target head rows')
    require(all(type(x['logicalBytes']) is int and x['logicalBytes']==1048576
        and type(x['allocationBound']) is int and x['allocationBound']>=1048576 for x in heads),'Dense head row allocation bounds')

def metadata_policy(value,job):
    require(value.get('targetProjectionPolicy')==POLICY,'Metadata must admit exact explicit dense target policy')
    require(value['targetExtraLogicalNativeBytes']=={128:43568162,4096:90508322}[job['promptCount']]
        and value['targetExtraHostBytes']==16*1048576+32768,'Dense target metadata logical budget')
