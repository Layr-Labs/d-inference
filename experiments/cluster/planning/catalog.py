"""Check the native export DTO's internal consistency, without enumerating cuts.

Native Plan remains responsible for model legality and fingerprint recipes.
This parser checks supplied metadata; it does not authenticate the exporter.
"""

from .costs import fields, integer, require, sha


SCOPE = dict(kind='qwen_layer_stage_candidate_catalog', schemaVersion=1,
             adapter='qwen35-dense-layer-stage-catalog-v1', metadataOnly=True,
             canonicalNameCoverageChecked=True, actualSanitizerVerified=False,
             sourceDescriptorsVerified=False, modelConstructed=False,
             checkpointWeightsRead=False, modelPayloadsVerified=False,
             allocationMeasured=False, runtimeEligibilityEstablished=False,
             performanceQualified=False, computeCostStatus='unknown',
             canonicalNamesEncoding='sorted_unique_strings_json_without_escaping_slashes_v1')


def name(value):
    require(type(value) is str and 1 <= len(value.encode('utf-8')) <= 512
            and all(ord(char) >= 32 and ord(char) != 127 for char in value),
            'Invalid exported metadata name')
    return value


def names(value, maximum=8192):
    require(type(value) is list and len(value) <= maximum, 'Exported names exceed bounds')
    result = {name(item) for item in value}
    require(len(result) == len(value), 'Duplicate exported metadata name')
    return result


def state_rows(stage, start, end):
    states = stage['state']
    require(type(states) is list and len(states) == end - start
            and integer(stage['stateLayerCount'], 'state layer count', 1, 128) == len(states),
            'Exported state count differs from layer range')
    components = dict(linear_attention=['conv', 'ssm'],
                      full_attention=['kv.keys', 'kv.values', 'kv.position_offsets'])
    for index, row in enumerate(states):
        fields(row, 'layer components', 'exported state')
        layer = fields(row['layer'], 'globalIndex localIndex kind', 'exported state layer')
        require(integer(layer['globalIndex'], 'global index', 0, 127) == start + index
                and integer(layer['localIndex'], 'local index', 0, 127) == index,
                'Exported state indices differ from layer range')
        require(type(layer['kind']) is str and layer['kind'] in components
                and row['components'] == components[layer['kind']],
                'Exported state kind or components differ')


def stage_rows(stage, rank):
    fields(stage, 'stageIndex sourceLayerRange stageFingerprint constructionConfigurationSHA256 '
           'parameters state activeModuleRoots inertModules parameterCount stateLayerCount computeCostStatus',
           'exported stage')
    require(integer(stage['stageIndex'], 'stage index', 0, 1) == rank
            and stage['computeCostStatus'] == 'unknown', 'Exported stage order or cost status differs')
    sha(stage['stageFingerprint'], 'native stage')
    sha(stage['constructionConfigurationSHA256'], 'native stage configuration')
    bounds = stage['sourceLayerRange']
    require(type(bounds) is list and len(bounds) == 2, 'Exported layer range must have two endpoints')
    start, end = [integer(value, 'layer endpoint', 0, 128) for value in bounds]
    require(start < end, 'Empty or reversed exported layer range')
    state_rows(stage, start, end)
    roots = names(stage['activeModuleRoots'], 131)
    inert = stage['inertModules']
    require(type(inert) is list and len(inert) <= 3, 'Exported inert modules exceed bounds')
    inert_paths = []
    for module in inert:
        fields(module, 'path responsibility', 'inert module')
        inert_paths.append(name(module['path']))
        name(module['responsibility'])
    require(not roots.intersection(names(inert_paths, 3)), 'Active and inert module roots overlap')
    parameters = stage['parameters']
    require(type(parameters) is list and 1 <= len(parameters) <= 8192
            and integer(stage['parameterCount'], 'parameter count', 1, 8192) == len(parameters),
            'Exported parameter count differs')
    sources, local = set(), set()
    for parameter in parameters:
        fields(parameter, 'sourceName localName stage', 'exported parameter')
        require(integer(parameter['stage'], 'parameter stage', 0, 1) == rank,
                'Exported parameter belongs to another stage')
        original, destination = name(parameter['sourceName']), name(parameter['localName'])
        require(original not in sources and destination not in local, 'Duplicate exported parameter mapping')
        sources.add(original)
        local.add(destination)
    return bounds, sources


def native_candidates(catalog):
    fields(catalog, ' '.join(SCOPE) + ' sourceConfigurationSHA256 canonicalNamesRawSHA256 '
           'canonicalNamesSHA256 canonicalNameCount candidates', 'native catalog')
    for key, value in SCOPE.items():
        require(type(catalog[key]) is type(value) and catalog[key] == value,
                'Candidate catalog scope differs: ' + key)
    for key in ('sourceConfigurationSHA256', 'canonicalNamesRawSHA256', 'canonicalNamesSHA256'):
        sha(catalog[key], key)
    count = integer(catalog['canonicalNameCount'], 'canonical name count', 1, 8192)
    candidates = catalog['candidates']
    require(type(candidates) is list and 1 <= len(candidates) <= 64,
            'Candidate catalog must contain bounded candidates')
    identities, cuts = set(), set()
    coverage, layer_end = None, None
    for candidate in candidates:
        fields(candidate, 'cut planFingerprint stages excludedCanonicalSourceNames computeCostStatus',
               'native candidate')
        require(candidate['computeCostStatus'] == 'unknown', 'Candidate must retain unknown compute cost')
        identity = sha(candidate['planFingerprint'], 'native plan')
        cut = integer(candidate['cut'], 'exported cut', 1, 127)
        require(identity not in identities and cut not in cuts, 'Duplicate native candidate identity or cut')
        identities.add(identity)
        cuts.add(cut)
        stages = candidate['stages']
        require(type(stages) is list and len(stages) == 2, 'Two native stages required')
        first, second = [stage_rows(stage, rank) for rank, stage in enumerate(stages)]
        require(first[0] == [0, cut] and second[0][0] == cut,
                'Exported cut and contiguous layer ranges disagree')
        excluded = names(candidate['excludedCanonicalSourceNames'])
        require(not first[1].intersection(second[1]) and not excluded.intersection(first[1] | second[1]),
                'Duplicated or excluded active source parameter')
        current = first[1] | second[1] | excluded
        require(len(current) == count, 'Declared canonical coverage differs')
        require(coverage is None or (coverage == current and layer_end == second[0][1]),
                'Candidates disagree about source coverage or total layers')
        coverage, layer_end = current, second[0][1]
    return candidates
