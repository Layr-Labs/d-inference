"""Require every actual discovered method, including both previously failed controls."""
import json,re
from context import BASE
from corrected_results import validate_swift_results

def validate(text):
    details=validate_swift_results(text)
    prior=json.loads((BASE/'prior-coverage.json').read_text())
    discovery=json.loads((BASE/'discovered-coverage.json').read_text())
    labels=re.findall(r'(?m)^✔ Test (.+?) passed after \d+(?:\.\d+)? seconds\.$',text)
    labels=[x for x in labels if not x.startswith('run with ')]
    for name in prior['priorCompletionLabels']:
        if labels.count(name)!=1:raise ValueError('Prior completion absent/repeated: '+name)
    for group,names in prior['groups'].items():
        for name in names:
            if labels.count(name+'()')!=1:raise ValueError('Required '+group+' method absent/repeated: '+name)
    if sorted(labels)!=discovery['completionLabels'] or len(labels)!=112 or details['testsPassed']!=112 or details['suitesPassed']!=18:
        raise ValueError('All 112 discovered methods and 18 suites must pass exactly once')
    details.update(priorCompletionLabelsPreserved=len(prior['priorCompletionLabels']),
        requiredMethodGroups={k:len(v) for k,v in prior['groups'].items()},invocationMethodsPassed=sum(map(len,prior['groups'].values())),
        actualDiscoveredMethodsPassed=112,allDiscoveredCompletionsPreserved=True)
    return details
