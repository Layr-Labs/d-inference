"""Independent default-half tensor expectations from pinned retained metadata."""
import base64
import hashlib
import importlib.util
import math
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
from stage_load_contract import bounded_regular, require, PROFILES

BASE_SHA = '21e17929e3af35f45d23101c3280ea061450c2a44865b3d7ab04c9ec3a2bb876'
PARENT_CONTRACT_SHA = '2d513be63bac7949743f2c5521e763199312bee5db714e811a0b1fdd47762cd6'
FIXTURE_SHA = '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
FIXTURE = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json')
ROOT = Path(__file__).resolve().parent


def base():
    for name, expected in [('constructor_metadata_base.py', BASE_SHA), ('stage_load_contract.py', PARENT_CONTRACT_SHA)]:
        require(hashlib.sha256(bounded_regular(ROOT/name, 65536)).hexdigest() == expected,
                'Frozen metadata helper changed: ' + name)
    spec = importlib.util.spec_from_file_location('_selected_metadata_base', ROOT/'constructor_metadata_base.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def exact(actual, expected, label):
    require(type(actual) is type(expected), 'Wrong metadata type at ' + label)
    if isinstance(expected, dict):
        require(set(actual) == set(expected), 'Wrong metadata keys at ' + label)
        for key in expected: exact(actual[key], expected[key], label + '.' + key)
    elif isinstance(expected, list):
        require(len(actual) == len(expected), 'Wrong metadata count at ' + label)
        for i, (a, b) in enumerate(zip(actual, expected)): exact(a, b, label + '[' + str(i) + ']')
    else:
        require(actual == expected, 'Metadata differs at ' + label)


def digest(value, label):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid digest at ' + label)
    return value


def expected(profile, fixture_path=FIXTURE):
    helper = base()
    raw = bounded_regular(fixture_path, 4 * 1024**2)
    require(helper.sha(raw) == FIXTURE_SHA, 'Retained registered metadata pin differs')
    fixture = helper.decode(raw)
    require(profile in PROFILES, 'Unknown registered profile')
    key, layers, hidden, inventory_pin = helper.PROFILES[profile]
    retained = fixture[key]
    config_raw = base64.b64decode(retained['configuration'], validate=True)
    manifest_raw = base64.b64decode(retained['manifest'], validate=True)
    manifest = helper.decode(manifest_raw)
    require(helper.sha(config_raw) == PROFILES[profile]['configuration'] and
            helper.sha(manifest_raw) == PROFILES[profile]['manifest'] and
            manifest['aggregate_sha256'] == PROFILES[profile]['artifact'], 'Registered raw metadata identity differs')
    canonical = sorted(retained['canonicalTensors'], key=lambda r: r['name'])
    require(len({r['name'] for r in canonical}) == len(canonical) == PROFILES[profile]['canonicalTensorCount'],
            'Retained canonical source is incomplete or duplicated')
    inventory = '\n'.join(f'{r["name"]}|{r["sourceDType"]}|{",".join(map(str,r["shape"]))}|{r["byteCount"]}' for r in canonical)
    require(helper.sha(inventory.encode()) == inventory_pin, 'Retained canonical inventory differs')
    source, active = [], [[], []]
    for tensor in canonical:
        shape = tensor['shape']; tag = tensor['sourceDType']
        require(type(shape) is list and shape and all(type(x) is int and x > 0 for x in shape), 'Invalid retained shape')
        source_type = helper.DTYPE[tag]
        require(type(tensor['byteCount']) is int and tensor['byteCount'] == math.prod(shape) * helper.WIDTH[source_type],
                'Retained canonical tensor byte count differs')
        loaded_type = 'bfloat16' if source_type == 'float16' else source_type
        row = dict(sourceName=tensor['name'], shape=shape, sourceDType=source_type,
                   loadedDType=loaded_type, byteCount=tensor['byteCount'])
        source.append(row)
        name = row['sourceName']; match = re.fullmatch(r'(language_model\.model\.layers\.)(\d+)(\..+)', name)
        if match:
            layer = int(match[2]); require(0 <= layer < layers, 'Global source layer outside registered model')
            owner = int(layer >= layers//2)
            local = match[1] + str(layer-owner*(layers//2)) + match[3]
        elif name.startswith('language_model.model.embed_tokens.'):
            owner, local = 0, name
        elif name.startswith('language_model.lm_head.') or name == 'language_model.model.norm.weight':
            owner, local = 1, name
        else:
            raise ValueError('Unknown registered source owner')
        active[owner].append(dict(row, localName=local))
    active = [sorted(rows, key=lambda r: r['localName']) for rows in active]
    inert = [[
        dict(path='language_model.lm_head', replacementKind='module-replacement',
             responsibility='Replace before parameter evaluation; stage 0 discards lazy logits',
             parameters=[dict(localName='language_model.lm_head.weight', shape=[1,hidden], dtype='bfloat16', byteCount=hidden*2)]),
        dict(path='language_model.model.norm', replacementKind='parameter-only-replacement',
             responsibility='Replace before parameter evaluation; stage 0 exports pre-final-norm hidden',
             parameters=[dict(localName='language_model.model.norm.weight', shape=[hidden], dtype='bfloat16', byteCount=hidden*2)])], [
        dict(path='language_model.model.embed_tokens', replacementKind='module-replacement',
             responsibility='Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype',
             parameters=[dict(localName='language_model.model.embed_tokens.weight', shape=[1,hidden], dtype='bfloat16', byteCount=hidden*2)])]]
    summaries = []
    for i, rows in enumerate(active):
        inert_parameters = [p for module in inert[i] for p in module['parameters']]
        layout = [dict(name=r['localName'], dtype=r['loadedDType'], shape=r['shape']) for r in rows]
        layout += [dict(name=r['localName'], dtype=r['dtype'], shape=r['shape']) for r in inert_parameters]
        summaries.append(dict(stageIndex=i, activeMappingSHA256=helper.sha(helper.canonical(rows)),
            activeParameterLayoutSHA256=helper.layout(rows,'localName','loadedDType'),
            parameterLayoutSHA256=helper.layout(layout,'name','dtype'),
            loadedTensorBytes=sum(r['byteCount'] for r in rows), activeTensorCount=len(rows),
            inertTensorBytes=sum(r['byteCount'] for r in inert_parameters), inertTensorCount=len(inert_parameters)))
    return dict(helper=helper, profile=profile, layers=layers, canonicalInventorySHA256=inventory_pin,
        source=source, active=active, inert=inert, summaries=summaries,
        sourceBytes=sum(r['byteCount'] for r in source), largestSourceBytes=max(r['byteCount'] for r in source),
        sourceLayoutSHA256=helper.layout(source,'sourceName','loadedDType'),
        configurationSHA256=helper.sha(config_raw), manifestSHA256=helper.sha(manifest_raw),
        artifactSHA256=manifest['aggregate_sha256'])
