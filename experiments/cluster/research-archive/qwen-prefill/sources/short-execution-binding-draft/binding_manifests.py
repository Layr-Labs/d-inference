"""Join explicit retained member bytes to the frozen parent's manifest schemas.

No historical origin path is opened. Source/build correlation, loaded Metal
library identity and directory ownership remain separate, unproven assertions.
"""
import re
from binding_common import canonical, fields, integer, path_text, pin, require, sha
from binding_pins import SUPPORTED_NATIVE_SOURCE_PINS

REQUIRED_SOURCES = {
    '.gitmodules', 'libs/mlx-swift/Package.swift', 'libs/mlx-swift-lm/Package.swift',
    *('experiments/cluster/inference/' + n for n in ('Package.swift', 'Package.resolved', 'build.sh', 'prepare_dependencies.py')),
    *('experiments/cluster/runtime/' + n for n in ('__init__.py', 'rank_worker.py', 'artifacts.py', 'bundle.py')),
}
BUNDLE_FIXED = {'cluster-inference', 'mlx.metallib', 'rank_worker.py', 'artifacts.py'}


def entries(value, maximum, where):
    require(type(value) is list and 1 <= len(value) <= maximum, where + ': invalid member count')
    result = {}
    for row in value:
        fields(row, 'path size_bytes sha256', where + ' member')
        path = path_text(row['path'], absolute=False)
        require(str(path) not in result, 'Duplicate manifest member')
        integer(row['size_bytes'], 'member bytes', high=1024**3)
        pin(row['sha256'])
        result[str(path)] = row
    return result


def source_manifest(value):
    fields(value, 'schema_version repository files dependencies', 'source manifest')
    require(type(value['schema_version']) is int and value['schema_version'] == 1, 'Wrong source schema')
    path_text(value['repository'], absolute=True)
    files = entries(value['files'], 8192, 'source')
    require(REQUIRED_SOURCES <= files.keys(), 'Source manifest omits required archive members')
    for path, row in files.items():
        allowed = (path in REQUIRED_SOURCES
                   or path.startswith('experiments/cluster/inference/Sources/') and path.endswith('.swift')
                   or path.startswith('experiments/cluster/runtime/') and path.endswith(('.py', '.md')))
        require(allowed and row['size_bytes'] <= 8*1024**2, 'Unsupported source archive member')
    for path, expected in SUPPORTED_NATIVE_SOURCE_PINS.items():
        require(path in files and files[path]['sha256'] == expected, 'Unsupported native report/arithmetic source')
    dependencies = fields(value['dependencies'], 'repository_head submodules tracked_dependency_changes', 'dependencies')
    require(type(dependencies['repository_head']) is str and re.fullmatch('[0-9a-f]{40}', dependencies['repository_head']),
            'Invalid repository commit assertion')
    require(type(dependencies['submodules']) is str and len(dependencies['submodules'].encode()) <= 1024**2
            and '\x00' not in dependencies['submodules'], 'Invalid dependency identity assertion')
    require(dependencies['tracked_dependency_changes'] == '', 'Recorded dependencies were dirty')
    return files


def bundle_manifest(value, sources):
    fields(value, 'schema_version files', 'bundle manifest')
    require(type(value['schema_version']) is int and value['schema_version'] == 1, 'Wrong bundle schema')
    files = entries(value['files'], 128, 'bundle')
    require(BUNDLE_FIXED <= files.keys(), 'Bundle manifest omits executable, metallib or runtime helpers')
    for path in files:
        require(path in BUNDLE_FIXED or path.startswith('mlx-swift-lm_MLXLMCommon.bundle/'),
                'Unsupported bundle member')
    for name in ('cluster-inference', 'mlx.metallib'):
        require(files[name]['size_bytes'] > 0, 'Empty executable or metallib member')
    for name in ('rank_worker.py', 'artifacts.py'):
        source = sources['experiments/cluster/runtime/' + name]
        require(files[name]['sha256'] == source['sha256'] and files[name]['size_bytes'] == source['size_bytes'],
                'Bundle helper differs from retained source')
    return files


def semantic_identity(source, sources, bundle):
    rows = lambda files: [files[key] for key in sorted(files)]
    return dict(sourceFilesAndDependenciesSHA256=sha(canonical(dict(files=rows(sources), dependencies=source['dependencies']))),
                bundleFilesSHA256=sha(canonical(rows(bundle))),
                nativeSHA256=bundle['cluster-inference']['sha256'],
                metallibSHA256=bundle['mlx.metallib']['sha256'])
