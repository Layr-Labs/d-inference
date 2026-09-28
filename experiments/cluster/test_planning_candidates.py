"""Fabricated metadata checks; no model legality or service measurement claim."""

import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from runtime.stage_checks.common import canonical, digest
from planning.catalog import SCOPE, native_candidates
from planning.candidates import associate
from planning.measurements.__main__ import main
from planning.measurements.catalog import associate_packet
from planning.measurements.ownership import HASHES, reported_ownership
from planning.measurements.packet import extract
from test_planning_measurements import write_packet


def reported(rank):
    source = dict(activeTensors=[dict(sourceName=f'source.{rank}', localName='model.layers.0.weight')])
    source.update({key: 'e' * 64 for key in HASHES})
    return dict(sourceLoad=source)


def add_reported(rows, traces):
    for rank in range(2):
        source = rows[rank][1]['sourceLoad']
        source['activeTensors'] = reported(rank)['sourceLoad']['activeTensors']
        for key in HASHES:
            source.setdefault(key, 'e' * 64)


def fabricated_catalog(services):
    source = services['source']
    candidates = []
    for cut in (12, 16, 20):
        stages = []
        for rank, (start, end) in enumerate(((0, cut), (cut, 32))):
            states = [dict(layer=dict(globalIndex=global_index, localIndex=global_index-start,
                                      kind='linear_attention'), components=['conv', 'ssm'])
                      for global_index in range(start, end)]
            stages.append(dict(stageIndex=rank, sourceLayerRange=[start, end],
                               stageFingerprint=source['stage_sha256'][rank] if cut == 16 else digest(f'{cut}:{rank}'.encode()),
                               constructionConfigurationSHA256=source['stage_configuration_sha256'][rank],
                               parameters=[dict(sourceName=f'source.{rank}', localName='model.layers.0.weight', stage=rank)],
                               state=states, activeModuleRoots=['model.layers.0'], inertModules=[],
                               parameterCount=1, stateLayerCount=end-start, computeCostStatus='unknown'))
        candidates.append(dict(cut=cut, planFingerprint=source['plan_sha256'] if cut == 16 else digest(str(cut).encode()),
                               stages=stages, excludedCanonicalSourceNames=['vision.weight'], computeCostStatus='unknown'))
    return dict(SCOPE, sourceConfigurationSHA256=source['configuration_sha256'],
                canonicalNamesRawSHA256='d'*64, canonicalNamesSHA256='c'*64, canonicalNameCount=3,
                candidates=candidates)


class CandidateAssociationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.packet = write_packet(self.folder, mutate=add_reported)
        self.services = extract(self.packet)
        self.catalog = fabricated_catalog(self.services)

    def test_exact_ownership_attaches_only_observed_candidate(self):
        result = associate(self.catalog, self.services)
        self.assertEqual([row['measurement_status'] for row in result['candidates']],
                         ['unmeasured', 'observed_metadata_match', 'unmeasured'])
        self.assertTrue(result['reported_parameter_ownership_matched'])
        self.assertEqual(result['candidates'][1]['services_semantic_sha256'], digest(canonical(self.services)))
        self.assertIsNone(result['candidates'][0]['services_semantic_sha256'])
        for flag in ('source_descriptor_or_weight_values_verified', 'physical_measurement_verified',
                     'execution_admission', 'performance_qualification'):
            self.assertFalse(result[flag])
        self.assertNotIn('ttft_ns', result)
        reversed_catalog = copy.deepcopy(self.catalog)
        reversed_catalog['candidates'].reverse()
        self.assertEqual([r['cut'] for r in associate(reversed_catalog, self.services)['candidates']], [20, 16, 12])

    def test_missing_and_partial_ownership_never_become_a_complete_match(self):
        for observed in ([None, None], [self.services['source']['reported_stage_ownership'][0], None],
                         [None, self.services['source']['reported_stage_ownership'][1]]):
            value = copy.deepcopy(self.services)
            value['source']['reported_stage_ownership'] = observed
            result = associate(self.catalog, value)
            self.assertFalse(result['reported_parameter_ownership_matched'])
            self.assertEqual(result['candidates'][1]['measurement_status'], 'ownership_missing')
            self.assertIsNone(result['candidates'][1]['services_semantic_sha256'])
        value['source']['reported_stage_ownership'][1]['active_mappings'][0]['local_name'] = 'wrong.weight'
        with self.assertRaisesRegex(ValueError, 'active ownership differ'):
            associate(self.catalog, value)

    def test_identity_and_explicit_cut_mismatches_refused(self):
        changes = [lambda c, s: c.update(sourceConfigurationSHA256='0'*64),
                   lambda c, s: s['source'].update(plan_sha256='0'*64),
                   lambda c, s: s['source']['stage_sha256'].__setitem__(1, '0'*64),
                   lambda c, s: s['source']['stage_configuration_sha256'].__setitem__(0, '0'*64),
                   lambda c, s: s['observed'].update(stage_cut=12),
                   lambda c, s: s['observed'].update(stage_cut=True)]
        for change in changes:
            catalog, services = copy.deepcopy(self.catalog), copy.deepcopy(self.services)
            change(catalog, services)
            with self.assertRaises(ValueError):
                associate(catalog, services)

    def test_catalog_rejects_contradictions_and_unknown_fields(self):
        changes = [lambda c: c['candidates'][1].update(cut=17),
                   lambda c: c['candidates'][1]['stages'][1].update(sourceLayerRange=[15, 32]),
                   lambda c: c['candidates'][1]['stages'][0].update(parameterCount=2),
                   lambda c: c['candidates'][1]['stages'][0]['state'][0]['layer'].update(localIndex=1),
                   lambda c: c['candidates'][1]['stages'][0]['parameters'][0].update(sourceName='source.1'),
                   lambda c: c['candidates'][1]['stages'][0]['parameters'][0].update(localName='bad\nname'),
                   lambda c: c['candidates'][1].update(excludedCanonicalSourceNames=['source.0']),
                   lambda c: c['candidates'][1].update(extra=True),
                   lambda c: c.update(nativeVerified=True),
                   lambda c: c.update(schemaVersion=True),
                   lambda c: c.update(canonicalNameCount=4),
                   lambda c: c.update(performanceQualified=True),
                   lambda c: c['candidates'].append(copy.deepcopy(c['candidates'][1]))]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                catalog = copy.deepcopy(self.catalog)
                change(catalog)
                with self.assertRaises(ValueError):
                    native_candidates(catalog)

    def test_malformed_service_metadata_refused_cleanly(self):
        for value in (None, [], {}, dict(self.services, source=None),
                      dict(self.services, source=dict(self.services['source'], stage_sha256=[]))):
            with self.assertRaises(ValueError):
                associate(self.catalog, value)
        for row in (True, {}, dict(stage_index=0, active_mappings=[], reported_hashes={})):
            services = copy.deepcopy(self.services)
            services['source']['reported_stage_ownership'][0] = row
            with self.assertRaises(ValueError):
                associate(self.catalog, services)

    def test_pinned_catalog_cli_and_changed_catalog_refusal(self):
        path = self.folder / 'catalog.json'
        raw = canonical(self.catalog) + b'\n'
        path.write_bytes(raw)
        args = ['measurements', str(self.packet), '--catalog', str(path), '--catalog-sha256', digest(raw)]
        output = io.StringIO()
        with patch('sys.argv', args), contextlib.redirect_stdout(output):
            self.assertEqual(main(), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result['catalog_raw_sha256'], digest(raw))
        self.assertEqual(result['packet_sha256'], digest(self.packet.read_bytes()))
        self.assertNotIn(str(self.folder), output.getvalue())
        with self.assertRaisesRegex(ValueError, 'Pinned native catalog bytes differ'):
            associate_packet(self.packet, path, '0'*64)
        def changed(_):
            path.write_bytes(raw + b' ')
            return self.services
        with patch('planning.measurements.catalog.extract', side_effect=changed):
            with self.assertRaisesRegex(ValueError, 'changed during extraction'):
                associate_packet(self.packet, path, digest(raw))

    def test_cli_requires_catalog_pin_and_excludes_projection(self):
        cases = [['--catalog', 'catalog.json'], ['--catalog-sha256', '0'*64],
                 ['--catalog', '', '--catalog-sha256', ''], ['--catalog-sha256', ''],
                 ['--catalog', ''], ['--catalog', '', '--catalog-sha256', '0'*64],
                 ['--catalog', 'catalog.json', '--catalog-sha256', '0'*64,
                  '--assume-independent-devices', 'a', 'b']]
        for extra in cases:
            with patch('sys.argv', ['measurements', str(self.packet), *extra]), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    main()
                self.assertEqual(error.exception.code, 2)


class ReportedOwnershipTests(unittest.TestCase):
    def test_missing_null_and_complete_inventory(self):
        self.assertEqual(reported_ownership([dict(sourceLoad={}), dict(sourceLoad=dict(activeTensors=None))]), [None, None])
        values = reported_ownership([reported(0), reported(1)])
        self.assertEqual([r['stage_index'] for r in values], [0, 1])
        self.assertEqual(values[0]['active_mappings'][0]['local_name'], values[1]['active_mappings'][0]['local_name'])

    def test_empty_duplicates_bad_names_and_missing_hash_refused(self):
        changes = [lambda r: r[0]['sourceLoad'].update(activeTensors=[]),
                   lambda r: r[1]['sourceLoad']['activeTensors'][0].update(sourceName='source.0'),
                   lambda r: r[0]['sourceLoad']['activeTensors'].append(dict(sourceName='unique', localName='model.layers.0.weight')),
                   lambda r: r[0]['sourceLoad']['activeTensors'][0].update(localName='bad/name'),
                   lambda r: r[0]['sourceLoad'].pop('activeMappingSHA256')]
        for change in changes:
            reports = [reported(0), reported(1)]
            change(reports)
            with self.assertRaises(ValueError):
                reported_ownership(reports)


if __name__ == '__main__':
    unittest.main()
