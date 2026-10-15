import copy
import unittest
from artifact import load_artifact, unique_pairs, validate_inventory
from geometry import LAYERS, PREFIX, expected_text_tensors, state_geometry, validate_geometry
from partition import make_partition


class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.artifact = load_artifact()

    def test_retained_header_index_inventory_join(self):
        a = self.artifact
        self.assertEqual(len(a['tensors']), 1697)
        self.assertEqual(len(expected_text_tensors()), 1339)
        self.assertEqual(sum(v['data_offsets'][1] - v['data_offsets'][0]
                             for v in a['tensors'].values()), 15608614044)

    def test_explicit_tied_replication_conservation(self):
        p = make_partition(self.artifact, 15)
        replicas = [x for x in p['parameters'] if x['replicaGroup']]
        self.assertEqual(len(replicas), 3)
        self.assertEqual(sum(x['headerDerivedPayloadBytes'] for x in replicas), 415236096)
        for row in replicas:
            self.assertEqual([x['role'] for x in row['destinations']],
                             ['ingressEmbedding', 'tiedOutputEmbedding'])
        self.assertEqual(p['uniqueTextPayloadBytes'], 14467688508)
        self.assertEqual(p['sumRankHeaderDerivedPayloadBytes'], 14882924604)
        self.assertEqual([x['destinationTensorCount'] for x in p['stages']], [672, 670])
        self.assertEqual([x['headerDerivedPayloadBytes'] for x in p['stages']],
                         [7437403934, 7445520670])
        self.assertEqual(p['excludedPayloadBytes'], 1140925536)
        self.assertFalse(p['wholePayloadHashesVerified'])
        self.assertFalse(p['nativeExecutionQualified'])

    def test_all_cuts_global_identity_and_destination_uniqueness(self):
        for cut in range(1, 30):
            p = make_partition(self.artifact, cut)
            destination_keys = []
            for row in p['parameters']:
                for target in row['destinations']:
                    destination_keys.append((target['rank'], target['localName']))
            self.assertEqual(len(set(destination_keys)), 1342)
            layers = [x for s in p['stages'] for x in s['layers']]
            self.assertEqual([x['globalIndex'] for x in layers], list(range(30)))
            self.assertEqual([x['kind'] for x in layers], LAYERS)
            self.assertEqual([s['globalLayerCountForConstructionAndKernelPolicy']
                              for s in p['stages']], [30, 30])
            self.assertIsNone(p['stages'][0]['finalTailOptimizationGlobalLayer'])
            self.assertEqual(p['stages'][1]['finalTailOptimizationGlobalLayer'], 29)

    def test_nonperiod_aligned_cut_preserves_global_attention(self):
        p = make_partition(self.artifact, 1)
        layer5 = p['stages'][1]['layers'][4]
        self.assertEqual(layer5, {'globalIndex': 5, 'localIndex': 4, 'kind': 'full_attention'})
        overrides = p['stages'][1]['localQuantizationOverrides']
        mapped = next(x for x in overrides if x['sourcePath'] == PREFIX + 'layers.5.router.proj')
        self.assertEqual(mapped['localPath'], PREFIX + 'layers.4.router.proj')
        self.assertEqual(mapped['policy'], {'bits': 8, 'group_size': 64})
        self.assertEqual(sum(len(s['localQuantizationOverrides']) for s in p['stages']), 120)

    def test_moe_and_shared_mlp_quantization_are_distinct(self):
        t = expected_text_tensors()
        root = PREFIX + 'layers.0.'
        self.assertEqual(t[root + 'experts.switch_glu.gate_proj.weight']['shape'], [128, 704, 352])
        self.assertEqual(t[root + 'mlp.gate_proj.weight']['shape'], [2112, 704])
        self.assertEqual(t[root + 'router.proj.weight']['shape'], [128, 704])
        self.assertEqual(t[root + 'experts.switch_glu.gate_proj.weight']['bytes'], 126877696)
        self.assertIn(PREFIX + 'layers.0.self_attn.v_proj.weight', t)
        self.assertNotIn(PREFIX + 'layers.5.self_attn.v_proj.weight', t)
        self.assertEqual(t[PREFIX + 'layers.5.self_attn.k_proj.weight']['shape'], [1024, 352])
        self.assertFalse(any('v_norm.weight' in name for name in t))

    def test_window_capacity_is_not_short_frontier_or_keqv_halved(self):
        s = state_geometry(15, 32, 16, 128)
        window, full = s['layers'][0], s['layers'][5]
        self.assertEqual(s['capacityTokens'], 160)
        self.assertEqual(s['completeLengthFrontier'], 159)
        self.assertEqual(window['retainedTokens'], 159)
        self.assertEqual(window['maximumStorageSlots'], 1024)
        self.assertEqual(window['logicalCapacityBytes'], 8388608)
        self.assertEqual(full['logicalCapacityBytes'], 655360)
        self.assertEqual(full['keyShape'], [1, 2, 159, 512])
        self.assertEqual(full['valueShape'], full['keyShape'])
        self.assertEqual(s['rankLogicalKVCapacityBytes'], [110362624, 102629376])
        self.assertEqual(s['namedStateEntries'], 90)
        self.assertEqual(s['recurrentLayers'], [])
        self.assertEqual(s['recurrentBytes'], 0)

    def test_wrapped_state_absolute_frontier_and_chunk_view(self):
        s = state_geometry(15, 8192, 512, 128)
        self.assertEqual(s['capacityTokens'], 8320)
        self.assertEqual(s['completeLengthFrontier'], 8319)
        self.assertEqual(s['layers'][0]['retainedTokens'], 1024)
        self.assertEqual(s['layers'][0]['retainedStart'], 7295)
        self.assertEqual(s['layers'][0]['maximumChunkAttentionViewTokens'], 1535)
        self.assertEqual(s['layers'][5]['retainedTokens'], 8319)
        self.assertEqual(s['rankLogicalKVCapacityBytes'], [177209344, 202899456])
        self.assertFalse(s['nativeKVDTypeVerified'])

    def test_changed_geometry_and_expert_override_refuse(self):
        for key, value in [('num_hidden_layers', 15), ('num_kv_shared_layers', 1),
                           ('hidden_size_per_layer_input', 1), ('attention_k_eq_v', False),
                           ('top_k_experts', 4), ('use_bidirectional_attention', 'all')]:
            c = copy.deepcopy(self.artifact['config'])
            c['text_config'][key] = value
            with self.assertRaises(ValueError):
                validate_geometry(c)
        c = copy.deepcopy(self.artifact['config'])
        c['quantization'][PREFIX + 'layers.0.experts.switch_glu.gate_proj'] = {'bits': 8, 'group_size': 64}
        with self.assertRaises(ValueError):
            validate_geometry(c)

    def test_index_mismatch_missing_tensor_and_changed_span_refuse(self):
        a = self.artifact
        index = copy.deepcopy(a['index'])
        index['weight_map'][PREFIX + 'embed_tokens.weight'] = 'model-00003-of-00003.safetensors'
        with self.assertRaises(ValueError):
            validate_inventory(a['manifest'], a['inventory'], index, a['headers'])
        inventory = copy.deepcopy(a['inventory'])
        del inventory['tensors'][PREFIX + 'layers.0.layer_scalar']
        with self.assertRaises(ValueError):
            validate_inventory(a['manifest'], inventory, a['index'], a['headers'])
        headers = copy.deepcopy(a['headers'])
        headers['model-00001-of-00003.safetensors'][0][PREFIX + 'embed_tokens.weight']['data_offsets'][0] += 4
        with self.assertRaises(ValueError):
            validate_inventory(a['manifest'], a['inventory'], a['index'], headers)

    def test_shape_cannot_hide_behind_same_byte_count(self):
        a = self.artifact
        headers, inventory = copy.deepcopy(a['headers']), copy.deepcopy(a['inventory'])
        name = PREFIX + 'layers.0.experts.switch_glu.gate_proj.weight'
        file = inventory['tensors'][name]['file']
        wrong = [64, 1408, 352]
        headers[file][0][name]['shape'] = wrong
        inventory['tensors'][name]['shape'] = wrong
        with self.assertRaises(ValueError):
            validate_inventory(a['manifest'], inventory, a['index'], headers)

    def test_request_cut_and_duplicate_json_refuse(self):
        for cut in [0, 30, -1, True, 1.5]:
            with self.assertRaises(ValueError):
                make_partition(self.artifact, cut)
        for p, c, o in [(8193, 512, 128), (32, 33, 128), (32, 16, 0), (32, 16, 129)]:
            with self.assertRaises(ValueError):
                state_geometry(15, p, c, o)
        with self.assertRaises(ValueError):
            unique_pairs([('same', 1), ('same', 2)])


if __name__ == '__main__':
    unittest.main()
