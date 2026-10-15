"""Fabricated CPU cases only; no native observations or historical file access."""

import builtins
from copy import deepcopy
import itertools
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from runtime_binding import (INT32_MAX, INT64_MAX, UINT64_MAX, FALSE_KEYS,
                             MAX_IDENTITY_BYTES, OPTIONAL_KEYS, REQUIRED_KEYS,
                             validate_runtime_pair)


LAUNCH = '/invented/run/bundle'
RESOLVED = '/invented/retained/native-source'
PID = 73


def runtime(root=LAUNCH):
    return dict(executableName='cluster-inference', mainBundleName=root.rsplit('/', 1)[1],
                executablePath=root + '/cluster-inference', mainBundlePath=root,
                mainBundleResourcePath=root, processID=PID,
                operatingSystemVersion='Version 26.2 (Build invented)',
                deviceArchitecture='fabricated-metal-architecture', deviceMemoryBytes=32 * 1024**3,
                maximumBufferBytes=16 * 1024**3, recommendedWorkingSetBytes=24 * 1024**3,
                binaryOrBundleHashVerifiedByNative=False, providerEligibilityEstablished=False,
                recommendedWorkingSetUsedForAdmission=False)


class RuntimePairTests(unittest.TestCase):
    def validate(self, first=None, second=None, pid=PID, paths=(LAUNCH,)):
        first = runtime() if first is None else first
        return validate_runtime_pair(first, deepcopy(first) if second is None else second, pid, paths)

    def reject_both(self, key, value):
        first = runtime(); first[key] = value
        with self.assertRaises(ValueError):
            self.validate(first)

    def test_flat_fresh_pair_identity_and_limits(self):
        result = self.validate()
        self.assertEqual(result['runtime'], runtime())
        self.assertTrue(result['runtimePairEqual'])
        self.assertTrue(result['processIDMatchesExpected'])
        self.assertTrue(result['executablePathMatchesAllowed'])
        self.assertEqual(result['naxAvailability'], 'unknown')
        for flag in ('hardwareIdentityAttested', 'runtimeFileBytesVerified',
                     'historicalPathsFollowed', 'providerEligibilityEstablished', 'executionAdmission'):
            self.assertIs(result[flag], False)
        self.assertLessEqual(len(json.dumps(result).encode()), MAX_IDENTITY_BYTES)

    def test_all_source_coherent_optional_omissions(self):
        for executable, resource, identifier in itertools.product((False, True), repeat=3):
            with self.subTest(executable=executable, resource=resource, identifier=identifier):
                value = runtime()
                if not executable:
                    del value['executablePath']; del value['executableName']
                if not resource:
                    del value['mainBundleResourcePath']
                if identifier:
                    value['bundleIdentifier'] = 'invented.test.identity'
                result = self.validate(value)
                self.assertEqual(set(result['runtime']), set(value))
                self.assertEqual(result['executablePathReported'], executable)
                self.assertEqual(result['executablePathMatchesAllowed'], True if executable else None)
                self.assertEqual(result['resourcePathReported'], resource)

    def test_optional_null_and_half_executable_pair_are_rejected(self):
        for key in OPTIONAL_KEYS:
            with self.subTest(null=key):
                self.reject_both(key, None)
        for key in ('executablePath', 'executableName'):
            first = runtime(); del first[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                self.validate(first)

    def test_reuse_resolved_path_and_mixed_valid_aliases(self):
        first = runtime(RESOLVED)
        result = self.validate(first, paths=(LAUNCH, RESOLVED))
        self.assertEqual(result['runtime']['mainBundleName'], 'native-source')
        first['executablePath'] = LAUNCH + '/cluster-inference'
        first['mainBundleResourcePath'] = LAUNCH
        a = self.validate(first, paths=(LAUNCH, RESOLVED))
        b = self.validate(first, paths=(RESOLVED, LAUNCH))
        self.assertEqual(a, b)
        self.assertTrue(a['executablePathMatchesAllowed'])

    def test_independently_valid_alias_switch_between_records_still_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(runtime(), runtime(RESOLVED), paths=(LAUNCH, RESOLVED))

    def test_requested_or_prefix_sibling_root_is_not_implicitly_allowed(self):
        for wrong in ('/invented/requested/link', LAUNCH + '-other', LAUNCH + '/child'):
            with self.subTest(wrong=wrong), self.assertRaises(ValueError):
                self.validate(runtime(wrong), paths=(LAUNCH, RESOLVED))

    def test_required_unknown_keys_and_object_types(self):
        for key in REQUIRED_KEYS:
            value = runtime(); del value[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                self.validate(value)
        for key in ('naxAvailable', 'unknown', 7):
            value = runtime(); value[key] = False
            with self.subTest(extra=key), self.assertRaises(ValueError):
                self.validate(value)
        for value in ([], None, 'object', 0):
            with self.subTest(type=type(value).__name__), self.assertRaises(ValueError):
                validate_runtime_pair(value, value, PID, [LAUNCH])

    def test_exact_native_false_flags(self):
        for key in FALSE_KEYS:
            for value in (True, 0, 1, None, 'false'):
                with self.subTest(key=key, value=value):
                    self.reject_both(key, value)

    def test_integer_bounds_and_bool_float_refusal(self):
        limits = {'processID': INT32_MAX, 'deviceMemoryBytes': INT64_MAX,
                  'maximumBufferBytes': INT64_MAX, 'recommendedWorkingSetBytes': UINT64_MAX}
        for key, maximum in limits.items():
            invalid = [-1, maximum + 1, True, False, 1.0, '1', None]
            if key != 'recommendedWorkingSetBytes':
                invalid.append(0)
            for value in invalid:
                with self.subTest(key=key, value=value):
                    self.reject_both(key, value)
        for pid in (0, -1, INT32_MAX + 1, True, 73.0, '73', None):
            with self.subTest(expected_pid=pid), self.assertRaises(ValueError):
                self.validate(pid=pid)
        value = runtime(); value['processID'] = INT32_MAX
        self.validate(value, pid=INT32_MAX)
        value = runtime(); value['recommendedWorkingSetBytes'] = 0
        self.validate(value)
        value['recommendedWorkingSetBytes'] = UINT64_MAX
        self.validate(value)

    def test_changed_pid_architecture_os_paths_and_limits(self):
        replacements = {'processID': PID + 1, 'deviceArchitecture': 'another-invented-architecture',
                        'operatingSystemVersion': 'Version 26.3 (Build invented)',
                        'deviceMemoryBytes': 64 * 1024**3, 'maximumBufferBytes': 8 * 1024**3,
                        'recommendedWorkingSetBytes': 12 * 1024**3,
                        'executablePath': RESOLVED + '/cluster-inference',
                        'mainBundleResourcePath': RESOLVED, 'bundleIdentifier': 'new.bundle.id'}
        for key, replacement in replacements.items():
            second = runtime(); second[key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(runtime(), second, paths=(LAUNCH, RESOLVED))
        with self.assertRaises(ValueError):
            self.validate(pid=PID + 1)

    def test_no_invented_hardware_or_advisory_ratio_gate(self):
        # Source DTO types do not assert a max-buffer/physical-memory ratio or
        # admission from the advisory working set. Equality is still required.
        value = runtime(); value['maximumBufferBytes'] = INT64_MAX
        value['recommendedWorkingSetBytes'] = UINT64_MAX
        self.validate(value)

    def test_invalid_text_unknown_device_and_names(self):
        for key in ('operatingSystemVersion', 'deviceArchitecture'):
            for value in ('', 'Unknown', 'unknown', ' unknown ', ' ', 'a\n', 'a\x00',
                          '\ud800', 'x' * 1025, '\u00e9' * 513, None, True):
                with self.subTest(key=key, value=repr(value)):
                    self.reject_both(key, value)
        for key, value in [('mainBundleName', 'different'), ('executableName', 'other'),
                           ('executableName', True), ('bundleIdentifier', ''),
                           ('bundleIdentifier', '\udfff')]:
            with self.subTest(key=key, value=repr(value)):
                self.reject_both(key, value)

    def test_invalid_paths_and_flat_resource_scope(self):
        wrong = ['relative/bundle', '/', '//invented/run/bundle', LAUNCH + '/',
                 '/invented/./bundle', '/invented/a/../bundle', '/invented//bundle',
                 '/invented/\\bundle', 'file://' + LAUNCH, '/a\x00/b',
                 '/' + 'a' * 4096, '/' + '\u00e9' * 2048]
        for path in wrong:
            with self.subTest(path=repr(path)), self.assertRaises(ValueError):
                self.validate(paths=[path])
        for path in (LAUNCH + '/Resources', LAUNCH + '/mlx-swift-lm_MLXLMCommon.bundle'):
            with self.subTest(resource=path):
                self.reject_both('mainBundleResourcePath', path)
        for key, value in [('mainBundlePath', '/other'),
                           ('executablePath', LAUNCH + '/other'),
                           ('mainBundleResourcePath', '/other')]:
            with self.subTest(key=key):
                self.reject_both(key, value)

    def test_allowed_path_container_and_caps(self):
        for value in ([], [LAUNCH, LAUNCH], [LAUNCH, RESOLVED, '/third'], LAUNCH,
                      {LAUNCH}, iter([LAUNCH]), [None], [1]):
            with self.subTest(container=type(value).__name__), self.assertRaises(ValueError):
                self.validate(paths=value)

    def test_detached_deterministic_result(self):
        first = runtime(); second = dict(reversed(list(first.items())))
        result = self.validate(first, second)
        self.assertEqual(list(result['runtime']), sorted(first))
        first['processID'] = 100; second['mainBundlePath'] = '/wrong'
        self.assertEqual(result['runtime']['processID'], PID)
        self.assertEqual(result['runtime']['mainBundlePath'], LAUNCH)

    def test_no_filesystem_or_runtime_work(self):
        def forbidden(*args, **kwargs):
            raise AssertionError('validator attempted filesystem access')
        with patch.object(builtins, 'open', forbidden), patch.object(Path, 'resolve', forbidden), \
                patch.object(Path, 'stat', forbidden), patch.object(Path, 'read_bytes', forbidden):
            self.validate(runtime(RESOLVED), paths=(LAUNCH, RESOLVED))


if __name__ == '__main__':
    unittest.main()
