"""Associate a native catalog with freshly extracted services by exact metadata.

The CLI supplies services directly from packet.extract. This association does
not replay services, authenticate the native exporter or recompute native hashes.
"""

from runtime.stage_checks.common import canonical, digest
from .catalog import native_candidates
from .costs import require, sha
from .measurements.ownership import ownership_pairs


def observed_source(services):
    require(type(services) is dict and services.get('schema') == 'cluster_prefill_services_v1',
            'Unsupported service record')
    source = services.get('source')
    require(type(source) is dict, 'Missing observed source metadata')
    for key in ('configuration_sha256', 'plan_sha256'):
        sha(source.get(key), 'observed ' + key)
    for key in ('stage_sha256', 'stage_configuration_sha256'):
        require(type(source.get(key)) is list and len(source[key]) == 2, 'Two observed stage identities required')
        for value in source[key]:
            sha(value, 'observed ' + key)
    workload, observed = services.get('workload'), services.get('observed')
    require(type(workload) is dict and type(observed) is dict, 'Missing workload or placement metadata')
    sha(workload.get('artifact_sha256'), 'observed artifact')
    return source


def associate(catalog, services):
    candidates = native_candidates(catalog)
    source = observed_source(services)
    require(catalog['sourceConfigurationSHA256'] == source['configuration_sha256'],
            'Catalog and observed source configuration differ')
    wanted = [candidate for candidate in candidates if candidate['planFingerprint'] == source['plan_sha256']]
    require(len(wanted) == 1, 'Observed native plan is absent from the catalog')
    matched = wanted[0]
    cut = services['observed'].get('stage_cut')
    require(cut is None or (type(cut) is int and cut == matched['cut']), 'Observed explicit cut differs')
    observed = source.get('reported_stage_ownership')
    require(type(observed) is list and len(observed) == 2, 'Two reported stage ownership slots required')
    for rank, stage in enumerate(matched['stages']):
        require(stage['stageFingerprint'] == source['stage_sha256'][rank]
                and stage['constructionConfigurationSHA256'] == source['stage_configuration_sha256'][rank],
                'Native stage or construction configuration differs')
        if observed[rank] is not None:
            actual = ownership_pairs(observed[rank], rank)
            expected = {(row['sourceName'], row['localName']) for row in stage['parameters']}
            require(actual == expected, 'Native catalog and reported active ownership differ')
    complete = all(stage is not None for stage in observed)
    services_sha = digest(canonical(services))
    # A new cut cannot inherit this observation's costs by layer fraction.
    return dict(schema='cluster_prefill_candidate_services_v1',
                catalog_semantic_sha256=digest(canonical(catalog)),
                services_semantic_sha256=services_sha,
                artifact_sha256=services['workload']['artifact_sha256'],
                candidates=[dict(cut=candidate['cut'], plan_sha256=candidate['planFingerprint'],
                                 measurement_status=('observed_metadata_match' if complete else 'ownership_missing')
                                 if candidate is matched else 'unmeasured',
                                 services_semantic_sha256=services_sha
                                 if candidate is matched and complete else None)
                            for candidate in candidates],
                observed_native_identity_matched=True, reported_parameter_ownership_matched=complete,
                source_descriptor_or_weight_values_verified=False,
                physical_measurement_verified=False, execution_admission=False,
                performance_qualification=False)
