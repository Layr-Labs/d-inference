"""Exact completed fixed-control accounting; no native fact is synthesized."""
from binding_common import require
POLICY='gemma4_remote_control_boundaries_owned_snapshot_v1'
FIELDS={'schema','policy','frameBytes','sends','receives','completedOperations','entryResourceChecks','exitResourceChecks','innerLifetimeChecks',
    'resourceValuesCachedAcrossOperations','snapshotResourceCadenceChanged','nativeCompletionFencesChanged','failed'}
COUNTS=('sends','receives','completedOperations','entryResourceChecks','exitResourceChecks','innerLifetimeChecks')
def validate_control_metrics(value):
    require(value['guardObservationPolicy']==value['controlResourceObservationPolicy']==POLICY,'Exact control resource policy')
    metrics=value['controlResourceMetrics']
    require(type(metrics) is dict and set(metrics)==FIELDS,'Exact control metric fields')
    require(metrics['schema']=='gemma4_remote_control_resource_counters_owned_snapshot_v1' and metrics['policy']==POLICY
        and type(metrics['frameBytes']) is int and metrics['frameBytes']==16384,'Fixed control metric identity')
    for name in COUNTS:
        require(type(metrics[name]) is int and 0<metrics[name]<=2**64-1,'Exact bounded control count: '+name)
    for name in ('snapshotResourceCadenceChanged','nativeCompletionFencesChanged'):
        require(metrics[name] is True,'Explicit changed snapshot chronology: '+name)
    for name in ('resourceValuesCachedAcrossOperations','failed'):
        require(metrics[name] is False,'Unestablished control claim: '+name)
    # Six cohort barriers contribute one send and receive on each rank. Every
    # completed request command likewise has exactly one matching response.
    require(metrics['sends']==metrics['receives'] and metrics['sends']>=6
        and metrics['completedOperations']==metrics['sends']+metrics['receives']
        and metrics['entryResourceChecks']==metrics['exitResourceChecks']==metrics['completedOperations']
        and metrics['innerLifetimeChecks']>=metrics['completedOperations'],'Control boundary/completion chronology')
    # The unchanged wall recorder wraps exactly each control operation body.
    rows=value['guardMetrics']['records']
    for category,count in [('wireSendCompleted',metrics['sends']),('wireReceiveCompleted',metrics['receives'])]:
        matches=[row for row in rows if row.get('category')==category]
        require(len(matches)==1 and type(matches[0].get('count')) is int
            and matches[0]['count']==count,'Control count differs from actual wire wall recorder')
    return metrics
