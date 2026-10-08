"""All inherited112 and exact five new methods must complete, including parameters."""
import json,re
from context import BASE
from corrected_results import validate_swift_results

def validate(text):
    details=validate_swift_results(text)
    prior=json.loads((BASE/'prior-coverage.json').read_text())
    expected=json.loads((BASE/'coverage.json').read_text())
    labels=re.findall(r'(?m)^✔ Test (.+?) passed after \d+(?:\.\d+)? seconds\.$',text)
    labels=[x for x in labels if not x.startswith('run with ')]
    for label in prior['priorCompletionLabels']:
        if labels.count(label)!=1:raise ValueError('Inherited completion absent/repeated: '+label)
    for group,names in prior['groups'].items():
        for name in names:
            if labels.count(name+'()')!=1:raise ValueError('Required '+group+' method absent/repeated: '+name)
    if sorted(labels)!=expected['completionLabels'] or len(labels)!=117 or details['testsPassed']!=117 or details['suitesPassed']!=19:
        raise ValueError('Exactly117 methods/19 suites including all prior112 and five additions required')
    details.update(priorCompletionLabelsPreserved=len(prior['priorCompletionLabels']),
        requiredMethodGroups={k:len(v) for k,v in prior['groups'].items()},invocationMethodsPassed=29,
        actualDiscoveredMethodsPassed=117,allDiscoveredCompletionsPreserved=True,newNumericalAndDriverMethodsPassed=5)
    return details
