"""Pure validation of existing QwenDenseStageLoadRuntimeObservation records.

Historical paths are compared as strings. This module never opens or resolves
them and does not establish binary identity, hardware attestation or NAX status.
"""

import json


MAX_PATH_BYTES = 4096
MAX_TEXT_BYTES = 1024
MAX_IDENTITY_BYTES = 32 * 1024
INT64_MAX = (1 << 63) - 1
UINT64_MAX = (1 << 64) - 1
INT32_MAX = (1 << 31) - 1

OPTIONAL_KEYS = frozenset((
    'executableName', 'bundleIdentifier', 'executablePath', 'mainBundleResourcePath',
))
FALSE_KEYS = frozenset((
    'binaryOrBundleHashVerifiedByNative', 'providerEligibilityEstablished',
    'recommendedWorkingSetUsedForAdmission',
))
REQUIRED_KEYS = frozenset((
    'mainBundleName', 'mainBundlePath', 'processID', 'operatingSystemVersion',
    'deviceArchitecture', 'deviceMemoryBytes', 'maximumBufferBytes',
    'recommendedWorkingSetBytes',
)) | FALSE_KEYS


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _text(value, label, maximum=MAX_TEXT_BYTES):
    _require(type(value) is str and 0 < len(value) <= maximum,
             label + ' must be a bounded nonempty string')
    try:
        size = len(value.encode('utf-8'))
    except UnicodeError as error:
        raise ValueError(label + ' is not valid UTF-8') from error
    _require(size <= maximum and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value),
             label + ' is oversized or contains control characters')
    return value


def _path(value, label):
    value = _text(value, label, MAX_PATH_BYTES)
    _require(value.startswith('/') and '\\' not in value,
             label + ' must be an absolute POSIX path')
    parts = value.split('/')[1:]
    _require(parts and all(part not in ('', '.', '..') for part in parts),
             label + ' must have an exact normalized historical spelling')
    return value


def _integer(value, label, minimum, maximum):
    _require(type(value) is int and minimum <= value <= maximum,
             label + ' has an invalid integer type or range')


def _allowed_paths(values):
    _require(type(values) in (list, tuple) and 1 <= len(values) <= 2,
             'Expected one fresh bundle root or at most two validated reuse aliases')
    paths = [_path(value, 'allowed bundle path') for value in values]
    _require(len(set(paths)) == len(paths), 'Duplicate allowed bundle path')
    return tuple(sorted(paths))


def _runtime(value, expected_pid, paths, label):
    _require(type(value) is dict and len(REQUIRED_KEYS) <= len(value) <= len(REQUIRED_KEYS | OPTIONAL_KEYS),
             label + ' must be the bounded native runtime object')
    _require(all(type(key) is str for key in value), label + ' runtime keys must be strings')
    keys = set(value)
    _require(REQUIRED_KEYS <= keys <= REQUIRED_KEYS | OPTIONAL_KEYS,
             label + ' native runtime keys differ')
    for key in FALSE_KEYS:
        _require(value[key] is False, label + ' ' + key + ' must be native false')
    _integer(value['processID'], label + ' processID', 1, INT32_MAX)
    _require(value['processID'] == expected_pid, label + ' processID differs from the parent')
    _integer(value['deviceMemoryBytes'], label + ' deviceMemoryBytes', 1, INT64_MAX)
    _integer(value['maximumBufferBytes'], label + ' maximumBufferBytes', 1, INT64_MAX)
    _integer(value['recommendedWorkingSetBytes'], label + ' recommendedWorkingSetBytes', 0, UINT64_MAX)
    for key in ('operatingSystemVersion', 'deviceArchitecture'):
        text = _text(value[key], label + ' ' + key)
        _require(text.strip() == text and text.casefold() not in ('unknown', ''),
                 label + ' ' + key + ' is unknown or has surrounding whitespace')
    main = _path(value['mainBundlePath'], label + ' mainBundlePath')
    _require(main in paths, label + ' main bundle is outside the allowed historical roots')
    _require(_text(value['mainBundleName'], label + ' mainBundleName') == main.rsplit('/', 1)[1],
             label + ' main bundle name differs from its path')
    # Both optional values are read from Bundle.main.executableURL. A nil URL
    # omits both fields through synthesized Swift Encodable; null is not emitted.
    has_executable = 'executablePath' in value
    _require(has_executable == ('executableName' in value), label + ' executable optionals are inconsistent')
    if has_executable:
        executable = _path(value['executablePath'], label + ' executablePath')
        _require(_text(value['executableName'], label + ' executableName') == 'cluster-inference' and
                 executable in tuple(path + '/cluster-inference' for path in paths),
                 label + ' executable identity differs from the flat native bundle')
    if 'mainBundleResourcePath' in value:
        resource = _path(value['mainBundleResourcePath'], label + ' mainBundleResourcePath')
        _require(resource in paths, label + ' resource path differs from the flat native bundle roots')
    if 'bundleIdentifier' in value:
        _text(value['bundleIdentifier'], label + ' bundleIdentifier')
    return {key: value[key] for key in sorted(value)}


def validate_runtime_pair(full_runtime, pair_runtime, expected_pid, allowed_bundle_paths):
    """Validate two existing native observations; return detached CPU identity.

    ``allowed_bundle_paths`` is one or two exact absolute POSIX root strings
    established by the caller's parent/bundle audit. Reuse may supply both the
    launch root and the validated ``bundleReference.resolvedPath``. The input
    ``requestedPath`` is not automatically a permitted alias. No path is followed.

    Swift nil optionals must be absent, not null. Missing executable path/name
    remains explicitly unavailable evidence. No equality of memory capacity and
    device limits is inferred beyond equality between the two native records.
    """
    _integer(expected_pid, 'expected PID', 1, INT32_MAX)
    paths = _allowed_paths(allowed_bundle_paths)
    full = _runtime(full_runtime, expected_pid, paths, 'full')
    pair = _runtime(pair_runtime, expected_pid, paths, 'pair')
    _require(full == pair, 'Full and pair native runtime observations differ')
    has_executable = 'executablePath' in full
    result = dict(
        schema='qwen_dense_runtime_pair_binding_v1', runtime=full,
        allowedBundlePaths=list(paths), runtimePairEqual=True, processIDMatchesExpected=True,
        bundlePathMatchesAllowed=True, executablePathReported=has_executable,
        executablePathMatchesAllowed=has_executable if has_executable else None,
        resourcePathReported='mainBundleResourcePath' in full,
        historicalPathsFollowed=False, runtimeFileBytesVerified=False,
        hardwareIdentityAttested=False, naxAvailability='unknown',
        providerEligibilityEstablished=False, executionAdmission=False,
    )
    encoded = json.dumps(result, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                         allow_nan=False).encode('utf-8')
    _require(len(encoded) <= MAX_IDENTITY_BYTES, 'Normalized runtime identity exceeds its bound')
    return result
