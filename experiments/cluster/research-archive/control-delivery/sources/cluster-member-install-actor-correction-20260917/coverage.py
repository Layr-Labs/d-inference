"""Retain every actual prior completion and exact new method groups."""
import json
import re
from context import BASE
from corrected_results import validate_swift_results

def validate(text):
    details=validate_swift_results(text)
    coverage=json.loads((BASE/'coverage.json').read_text())
    labels=re.findall(r'(?m)^✔ Test (.+?) passed after \d+(?:\.\d+)? seconds\.$',text)
    labels=[x for x in labels if not x.startswith('run with ')]
    for name in coverage['priorCompletionLabels']:
        if labels.count(name)!=1:raise ValueError('Prior passed case absent/repeated: '+name)
    for group,names in coverage['groups'].items():
        for name in names:
            if labels.count(name+'()')!=1:raise ValueError('Required '+group+' method absent/repeated: '+name)
    if len(labels)!=details['testsPassed']:raise ValueError('Per-test completion/summary count differs')
    details.update(priorCompletionLabelsPreserved=len(coverage['priorCompletionLabels']),requiredMethodGroups={k:len(v) for k,v in coverage['groups'].items()},invocationMethodsPassed=sum(map(len,coverage['groups'].values())))
    return details
