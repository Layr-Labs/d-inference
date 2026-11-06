"""Source-based regression for the v1 Plan-order/receipt-order expectation bug."""
from pathlib import Path
import unittest

from tiny12_expected import expected, inert, sha
from tiny12_fixture import suffix
from tiny_unequal_audit import validate_suffix


class InertReceiptOrderTests(unittest.TestCase):
    def test_actual_archived_loader_sort_contract(self):
        folder = Path(__file__).parent / 'source-correction'
        pins = {
            'QwenLayerStageInert.swift': 'e4339c65239c5a7aa8d55cec777d76368410eddc5731445364c4acc0cb6e54a6',
            'PreparedQwenLayerStage.swift': '4a838e67143fde0824271f0e3b4e5bed9a99941e47787833cd1e1e718d340910',
            'VerifiedQwenLayerStageLoading.swift': '90bdb29b40fa665cedb29c8630bba943d8be098beed1c856a1a117a326c63d0b',
        }
        sources = {}
        for name, pin in pins.items():
            raw = (folder / name).read_bytes()
            self.assertEqual(sha(raw), pin)
            sources[name] = raw.decode()
        self.assertIn('return try stage.inertModules.sorted(by: { $0.path < $1.path }).map { item in',
                      sources['QwenLayerStageInert.swift'])
        self.assertIn('let inert = try installQwenStageInertParameters(model: model, stage: stage,',
                      sources['PreparedQwenLayerStage.swift'])
        self.assertIn('inertModules: inventory.inert, inertTensorBytes: summary.inertTensorBytes,',
                      sources['VerifiedQwenLayerStageLoading.swift'])
        self.assertEqual([item['path'] for item in expected()['stages'][0]['inertModules']],
                         ['language_model.lm_head', 'language_model.model.norm'])

    def test_plan_identity_order_is_not_changed(self):
        self.assertEqual([item['path'] for item in inert(0)],
                         ['language_model.model.norm', 'language_model.lm_head'])
        value = expected()
        self.assertEqual(value['planSHA256'], 'ec32cb26ae3acf849f9dc4656b80023bd7f5912e680ee1095dc255cf2518d628')
        self.assertEqual([stage['stagePlanSHA256'] for stage in value['stages']],
            ['767198c7f6f941497a2d51ef2072a71ac6a990d2abafcbd5ba42a427f1b9de87',
             'd7e87ec287469e11fc5b20de69a2b2fcaf30a5c95f615fa5a0985d0e6ba172b7'])

    def test_expected_receipt_passes_and_plan_order_is_rejected(self):
        checkpoint, wrapper = suffix()
        self.assertEqual(validate_suffix(checkpoint, wrapper)['inventory']['canonicalTensors'], 352)
        wrapper['comparison']['stageLoads'][0]['inertModules'].reverse()
        with self.assertRaisesRegex(ValueError, 'stage metadata differs: inertModules'):
            validate_suffix(checkpoint, wrapper)

    def test_sorted_order_does_not_relax_inert_content(self):
        for mutation in ('shape', 'responsibility', 'duplicate'):
            checkpoint, wrapper = suffix()
            items = wrapper['comparison']['stageLoads'][0]['inertModules']
            if mutation == 'shape':
                items[0]['parameters'][0]['shape'] = [128,1]
            elif mutation == 'responsibility':
                items[0]['responsibility'] = 'changed'
            else:
                items[1] = items[0]
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, 'stage metadata differs: inertModules'):
                validate_suffix(checkpoint, wrapper)


if __name__ == '__main__':
    unittest.main()
