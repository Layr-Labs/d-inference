"""Retain reported active-name mappings for exact native-candidate association.

This validates mapping syntax/uniqueness only. Shapes, dtypes, native digest
recipes and weight values remain the separate loader/numerical audit's scope.
"""

import re
from ..costs import fields, require, sha


HASHES = ('activeMappingSHA256', 'activeParameterLayoutSHA256',
          'sourceTensorManifestSHA256', 'parameterLayoutSHA256')


def ownership_pairs(stage, rank):
    fields(stage, 'stage_index active_mappings reported_hashes', 'reported ownership')
    require(type(stage['stage_index']) is int and stage['stage_index'] == rank,
            'Reported ownership stage differs')
    fields(stage['reported_hashes'], ' '.join(HASHES), 'reported ownership hashes')
    for key, value in stage['reported_hashes'].items():
        sha(value, 'reported ' + key)
    rows = stage['active_mappings']
    require(type(rows) is list and 1 <= len(rows) <= 8192, 'Reported mappings exceed bounds')
    sources, local, pairs = set(), set(), set()
    for row in rows:
        fields(row, 'source_name local_name', 'reported mapping')
        original, destination = row['source_name'], row['local_name']
        for name in (original, destination):
            require(type(name) is str and re.fullmatch('[A-Za-z0-9_.]{1,512}', name),
                    'Invalid reported canonical parameter name')
        require(original not in sources and destination not in local, 'Duplicate reported ownership')
        sources.add(original)
        local.add(destination)
        pairs.add((original, destination))
    return pairs


def reported_ownership(reports):
    require(type(reports) is list and len(reports) == 2, 'Two rank reports required')
    stages, source_names = [], set()
    for rank, report in enumerate(reports):
        require(type(report) is dict and type(report.get('sourceLoad')) is dict,
                'Missing source loader report')
        source = report['sourceLoad']
        tensors = source.get('activeTensors')
        # Older reports may omit this optional inventory. Explicit null also
        # denotes missing evidence; an empty list is a contradictory inventory.
        if tensors is None:
            stages.append(None)
            continue
        require(type(tensors) is list and 1 <= len(tensors) <= 8192,
                'Reported active tensor mappings exceed bounds')
        mappings = []
        for tensor in tensors:
            require(type(tensor) is dict, 'Reported active tensor must be an object')
            mappings.append(dict(source_name=tensor.get('sourceName'), local_name=tensor.get('localName')))
        stage = dict(stage_index=rank, active_mappings=mappings,
                     reported_hashes={key: source.get(key) for key in HASHES})
        originals = {original for original, _ in ownership_pairs(stage, rank)}
        require(not originals.intersection(source_names), 'Duplicate reported source across stages')
        source_names.update(originals)
        stages.append(stage)
    return stages
