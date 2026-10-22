"""Replay the frozen completed-parent record and its cross-file identities."""
import base64
from pathlib import Path
from binding_common import fields, integer, parse, path_text, pin, require, same
from binding_inputs import snapshot
from binding_pins import PARENT_CONTRACT_PIN, PRIVATE_SOURCE_PINS


def schema():
    value = snapshot(Path(__file__).resolve().parent / 'parent-contract.json', 65536)
    require(value['sha256'] == PARENT_CONTRACT_PIN, 'Pinned parent schema changed')
    return parse(value['raw'])


def absolute_label(value):
    """The parent preserves requested paths as labels, without resolving them."""
    require(type(value) is str and value.startswith('/') and 0 < len(value.encode()) <= 4096
            and '\x00' not in value, 'Invalid original absolute path label')


def command_binding(parent, contract, source):
    for name in ('runtime', 'release', 'modelDirectory'):
        path_text(parent[name], absolute=True)
    for name in ('promptFile', 'teacherFile'):
        absolute_label(parent[name])
    require(parent['runtime'] == source['repository'] + '/experiments/cluster/runtime', 'Parent source root differs')
    command = parent['command']
    require(type(command) is list and len(command) == 17, 'Native command geometry differs')
    executable = path_text(command[0], absolute=True)
    require(executable.name == 'cluster-inference' and executable.parent.name == 'bundle', 'Wrong launch bundle command')
    root = executable.parent.parent
    require(str(root) != '/', 'Invalid historical run root')
    for boundary in (source['repository'], parent['modelDirectory'], parent['release']):
        forbidden = path_text(boundary, absolute=True)
        require(root != forbidden and forbidden not in root.parents, 'Historical output overlaps an excluded origin')
    expected = contract.native_command(executable, parent['modelDirectory'], parent['registeredProfile'],
                                       root / 'prompt.json', root / 'teacher.json',
                                       parent['expectedPromptSHA256'], parent['expectedTeacherSHA256'])
    same(command, expected, 'Exact native command')
    return str(executable), str(executable.parent)


def bundle_binding(parent, bundle, launch):
    if parent['bundleAcquisition'] == 'fresh_snapshot':
        same(parent['bundleCopiedForThisRun'], True, 'fresh bundle copy')
        return [launch]
    same(parent['bundleCopiedForThisRun'], False, 'reused bundle copy')
    same(parent['bundleReferenceHelperSHA256'], PRIVATE_SOURCE_PINS['owned_bundle_reference.py'], 'reuse helper')
    reference = fields(parent['bundleReference'], 'kind schemaVersion requestedPath resolvedPath copied '
                       'manifestSHA256 expectedNativeSHA256 verifiedFileCount runtimeFilesSHA256', 'reuse reference')
    for key, value in dict(kind='owned_read_only_bundle_reference', schemaVersion=1, copied=False,
                           manifestSHA256=parent['bundleManifestSHA256'], expectedNativeSHA256=parent['expectedNativeSHA256'],
                           verifiedFileCount=len(bundle)).items():
        same(reference[key], value, 'reuse ' + key)
    absolute_label(reference['requestedPath'])
    path_text(reference['resolvedPath'], absolute=True)
    expected = {name:bundle[name]['sha256'] for name in ('rank_worker.py', 'artifacts.py')}
    same(reference['runtimeFilesSHA256'], expected, 'reuse runtime helpers')
    require(reference['resolvedPath'] != launch, 'Reused bundle would reference itself')
    return [launch, reference['resolvedPath']]


def validate_parent(parent, profile, core, source, sources, bundle, outer, tokens, contract):
    specification = schema()
    require(type(parent) is dict, 'Missing completed parent')
    branch = parent.get('bundleAcquisition')
    require(type(branch) is str and branch in specification['exactTopLevelKeySets'], 'Unknown bundle acquisition')
    fields(parent, ' '.join(specification['exactTopLevelKeySets'][branch]), 'completed parent')
    for name, value in specification['exactTypedValuesForBothBranches'].items():
        same(parent[name], value, 'parent ' + name)
    require(type(profile) is str and profile in contract.PROFILES, 'Unsupported registered profile')
    same(parent['registeredProfile'], profile, 'parent profile')
    same(parent['expectedIdentity'], contract.PROFILES[profile], 'registered metadata identity')
    same(parent['maximumSampledNativeRSSBytes'], contract.PROFILES[profile]['maximumSampledRSSBytes'], 'RSS screen')
    integer(parent['nativePID'], 'parent native PID', low=1, high=2**31-1)
    for name in specification['lowercase64HexStringFields']:
        pin(parent[name])
    same(parent['privateSourceSHA256'], PRIVATE_SOURCE_PINS, 'frozen parent sources')
    same(parent['sourceFileCount'], len(sources), 'retained source count')
    same(parent['sourceManifestSHA256'], core['source_manifest']['sha256'], 'source manifest pin')
    same(parent['bundleManifestSHA256'], core['bundle_manifest']['sha256'], 'bundle manifest pin')
    same(parent['expectedNativeSHA256'], bundle['cluster-inference']['sha256'], 'native member pin')
    same(parent['rawTokenInputs'], tokens, 'raw token metadata')
    for role, key in (('prompt', 'expectedPromptSHA256'), ('teacher', 'expectedTeacherSHA256')):
        same(parent[key], core[role]['sha256'], 'raw ' + role + ' pin')
    for role, key in (('stdout', 'stdout.jsonl'), ('stderr', 'stderr.log')):
        same(parent[key], dict(sizeBytes=core[role]['size_bytes'], sha256=core[role]['sha256'],
                               hashOmittedBecauseOversized=False), 'raw ' + role + ' record')
    require(core['stderr']['raw'] == b'', 'Native stderr must be empty')
    retained = parse(core['retained_metadata']['raw'])
    item = retained['nine' if profile == 'registered_qwen35_9b' else 'twentySeven']
    expected_metadata = {name:dict(sizeBytes=len(base64.b64decode(item[key], validate=True)),
                                 sha256=contract.PROFILES[profile][key])
                         for name, key in (('config.json', 'configuration'), ('manifest.json', 'manifest'))}
    same(parent['rawMetadataPins'], expected_metadata, 'registered raw metadata')
    for key, value in outer.items():
        same(parent[key], value, 'fresh outer replay ' + key)
    executable, launch = command_binding(parent, contract, source)
    allowed = bundle_binding(parent, bundle, launch)
    return dict(executable=executable, allowedBundlePaths=allowed, nativePID=parent['nativePID'])
