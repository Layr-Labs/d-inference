"""Explicit two-stage destinations, including one declared tied replica group."""
import hashlib
import json
from geometry import DTYPE_BYTES, LAYERS, PREFIX, require


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def make_partition(artifact, cut):
    require(type(cut) is int and 1 <= cut < 30, "cut must be in 1..<30")
    parameters, excluded, destinations = [], [], set()
    text_bytes = 0
    for name, tensor in sorted(artifact['tensors'].items()):
        size = tensor['data_offsets'][1] - tensor['data_offsets'][0]
        if not name.startswith('language_model.'):
            excluded.append({"sourceName": name, "component": name.split('.')[0],
                             "headerDerivedPayloadBytes": size})
            continue
        text_bytes += size
        if name.startswith(PREFIX + 'embed_tokens.'):
            targets = [(0, name, 'ingressEmbedding'), (1, name, 'tiedOutputEmbedding')]
            replica = 'source-tied-embedding-v1'
        elif name == PREFIX + 'norm.weight':
            targets, replica = [(1, name, 'finalNorm')], None
        else:
            suffix = name.removeprefix(PREFIX + 'layers.')
            layer, leaf = suffix.split('.', 1)
            global_index = int(layer)
            require(str(global_index) == layer and 0 <= global_index < 30, 'layer name')
            rank = int(global_index >= cut)
            local = global_index if rank == 0 else global_index - cut
            targets = [(rank, PREFIX + f'layers.{local}.' + leaf, 'exclusiveLayer')]
            replica = None
        target_rows = []
        for rank, local, role in targets:
            require((rank, local) not in destinations, 'destination collision')
            destinations.add((rank, local))
            target_rows.append({"rank": rank, "localName": local, "role": role})
        parameters.append({"sourceName": name, "sourceDescriptor": tensor,
                           "headerDerivedPayloadBytes": size, "replicaGroup": replica,
                           "destinations": target_rows})
    stages = []
    for rank, (start, stop) in enumerate([(0, cut), (cut, 30)]):
        policies = []
        for path, policy in sorted(artifact['config']['quantization'].items()):
            if not isinstance(policy, dict):
                continue
            global_index = int(path.removeprefix(PREFIX + 'layers.').split('.', 1)[0])
            if start <= global_index < stop:
                local_path = path.replace(PREFIX + f'layers.{global_index}.',
                                          PREFIX + f'layers.{global_index - start}.', 1)
                policies.append({"sourcePath": path, "localPath": local_path, "policy": policy})
        count = sum(len([x for x in row['destinations'] if x['rank'] == rank]) for row in parameters)
        size = sum(row['headerDerivedPayloadBytes'] for row in parameters
                   if any(x['rank'] == rank for x in row['destinations']))
        stages.append({"rank": rank, "sourceRange": [start, stop],
            "globalLayerCountForConstructionAndKernelPolicy": 30,
            "localLayerCount": stop - start,
            "layers": [{"globalIndex": i, "localIndex": i - start, "kind": LAYERS[i]}
                       for i in range(start, stop)],
            "ownsInputLookup": rank == 0, "ownsFinalNormAndTiedProjection": rank == 1,
            "retainsFullResidualRowsAtBoundary": rank == 0,
            "finalTailOptimizationGlobalLayer": 29 if rank == 1 else None,
            "quantizationDefaults": {"bits": 4, "group_size": 64, "mode": "affine"},
            "localQuantizationOverrides": policies,
            "destinationTensorCount": count, "headerDerivedPayloadBytes": size})
    replica_bytes = sum(row['headerDerivedPayloadBytes'] for row in parameters if row['replicaGroup'])
    require(sum(s['headerDerivedPayloadBytes'] for s in stages) == text_bytes + replica_bytes,
            'replica accounting')
    require(len(parameters) == 1339 and len(destinations) == 1342 and len(excluded) == 358,
            'partition count')
    value = {"schema": "private-gemma4-text-partition-contract-v1", "cut": cut,
        "artifactAggregateSHA256Declared": artifact['manifest']['aggregate_sha256'],
        "wholePayloadHashesVerified": False, "nativeExecutionQualified": False,
        "sourceConfigSHA256": artifact['pins'][1]['sha256'],
        "sourceTensorCount": 1697, "textSourceTensorCount": 1339,
        "destinationTensorCount": 1342, "uniqueTextPayloadBytes": text_bytes,
        "replicatedTiedEmbeddingAdditionalBytes": replica_bytes,
        "sumRankHeaderDerivedPayloadBytes": text_bytes + replica_bytes,
        "excludedPayloadBytes": sum(x['headerDerivedPayloadBytes'] for x in excluded),
        "stages": stages, "parameters": parameters, "excluded": excluded}
    value['metadataContractSHA256'] = hashlib.sha256(canonical(value)).hexdigest()
    return value
