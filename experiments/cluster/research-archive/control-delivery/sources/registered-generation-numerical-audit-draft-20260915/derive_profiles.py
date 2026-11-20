#!/usr/bin/env python3
"""Replay fixed profile metadata from retained bytes; no model payload or execution."""
import base64
import importlib.util
import json
from pathlib import Path
from recorded_math import digest, require

BASE = Path(__file__).resolve().parent


def legacy_constants():
    spec = importlib.util.spec_from_file_location('frozen_audit_common', BASE / 'originals/audit_common.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def derive():
    retained = json.loads((BASE / 'inputs/retained-inputs.json').read_text())
    metadata = json.loads((BASE / 'inputs/recording-metadata.json').read_text())
    old = legacy_constants()
    result = {}
    for name, model_id, cut in [('nine', 'registered_qwen35_9b', 4),
                               ('twentySeven', 'registered_qwen38_27b', 32)]:
        item = retained[name]
        config_bytes = base64.b64decode(item['configuration'], validate=True)
        manifest_bytes = base64.b64decode(item['manifest'], validate=True)
        config = json.loads(config_bytes)['text_config']
        manifest = json.loads(manifest_bytes)
        tensors = item['canonicalTensors']
        require(len({t['name'] for t in tensors}) == len(tensors), 'Duplicate source tensor')
        dtype = {'U32': 'uint32', 'BF16': 'bfloat16', 'F16': 'bfloat16', 'F32': 'float32'}
        # QwenDenseObservedTensor.layoutEntry / parameterLayoutFingerprint spelling.
        layout = sorted(t['name'] + ':' + dtype[t['sourceDType']] + ':' + str(t['shape']) for t in tensors)
        value = dict(modelID=model_id, artifact=manifest['aggregate_sha256'],
            configuration=digest(config_bytes), manifest=digest(manifest_bytes),
            layers=config['num_hidden_layers'], hidden=config['hidden_size'], vocab=config['vocab_size'],
            interval=config['full_attention_interval'], kv_heads=config['num_key_value_heads'],
            head_dim=config['head_dim'], linear_value_heads=config['linear_num_value_heads'],
            linear_key_dim=config['linear_key_head_dim'], linear_value_dim=config['linear_value_head_dim'],
            conv_history=config['linear_conv_kernel_dim'] - 1,
            conv_channels=2*config['linear_num_key_heads']*config['linear_key_head_dim']
                          + config['linear_num_value_heads']*config['linear_value_head_dim'],
            layout=digest('\n'.join(layout).encode()), source_count=len(tensors),
            source_bytes=sum(t['byteCount'] for t in tensors), largest=max(t['byteCount'] for t in tensors),
            profile_id=model_id + '_greedy_generation_v1')
        expected_types = [('full_attention' if (i+1) % value['interval'] == 0 else 'linear_attention')
                          for i in range(value['layers'])]
        require(config['layer_types'] == expected_types, 'Unexpected layer phase')
        if name == 'nine':
            for key, expected in dict(artifact=old.ARTIFACT, configuration=old.CONFIG,
                    manifest=old.MANIFEST, layout=old.LAYOUT).items():
                require(value[key] == expected, 'Frozen9B metadata differs: ' + key)
            plan = dict(fingerprint=old.PLAN, stages=old.STAGES, constructions=old.CONSTRUCTIONS)
        else:
            for key, source in [('artifact', 'artifactSHA256'), ('configuration', 'configurationSHA256'),
                                ('manifest', 'manifestSHA256'), ('modelID', 'modelID')]:
                require(value[key] == metadata[source], 'Actual metadata helper differs: ' + key)
            require(sum(metadata['canonicalCounts']) == value['source_count']
                    and sum(metadata['activeBytes']) == value['source_bytes'], 'Helper coverage differs')
            require(metadata['stageCut'] == cut and metadata['modelPayloadRead'] is False
                    and metadata['nativeExecuted'] is False, 'Metadata-only helper scope differs')
            plan = dict(fingerprint=metadata['planSHA256'], stages=metadata['stagePlanSHA256'],
                        constructions=metadata['constructionConfigurationSHA256'])
        value['plans'] = {str(cut): plan}
        result[model_id] = value
    return result


def verify():
    expected = json.loads((BASE / 'registered_profiles.json').read_text())
    require(derive() == expected, 'Registered profile catalog differs from retained source replay')
    return dict(status='passed', profiles=len(expected), payloadRead=False, nativeExecuted=False)


if __name__ == '__main__':
    print(json.dumps(verify(), sort_keys=True))
