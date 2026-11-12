"""Source-backed CPU preflight; not execution of the Swift decoder or an owner."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import uuid

CONTROLLER = set('schema cpuQualification clusterID readyTemplateBase64 peers membershipEpoch requestID promptTokenIDs stopTokenIDs outputCount chunkSize expectedTokenIDs lifetimeSeconds startupSeconds requestSeconds'.split())
OWNER = set('schema clusterID workerExecutable modelDirectory leaseDirectory stageCut maximumLifetimeSeconds workerEnvironment readyTemplateBase64'.split())


def require(value, message):
    if not value:
        raise ValueError(message)


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate worker JSON key')
            result[key] = value
        return result
    def noninteger(_):
        raise ValueError('Worker JSON requires integer syntax')
    def integer(text):
        require(len(text) <= 20, 'Worker JSON integer lexical bound')
        return int(text)
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_int=integer,
                       parse_float=noninteger, parse_constant=noninteger)
    def depth(item, n):
        require(n <= 16, 'Worker JSON nesting bound')
        if type(item) is dict:
            for child in item.values(): depth(child, n + 1)
        elif type(item) is list:
            for child in item: depth(child, n + 1)
    depth(value, 0)
    return value


def framed(raw, maximum, append_missing=False):
    if append_missing and not raw.endswith(b'\n'):
        raw += b'\n'
    require(0 < len(raw) <= maximum and raw[-1:] == b'\n' and b'\n' not in raw[:-1],
            'Expected one bounded owner JSONL record')
    return strict_json(raw)


def ready_template(encoded):
    require(type(encoded) is str, 'Template must be base64 text')
    raw = base64.b64decode(encoded, validate=True)
    value = framed(raw, 16*1024)
    require(type(value) is dict and set(value) == {'kind', 'membershipEpoch', 'ready', 'sequence', 'version'}, 'Ready envelope fields')
    require(value['kind'] == 'ready' and type(value['version']) is int and value['version'] == 1, 'Ready event/version')
    require(type(value['sequence']) is int and 0 <= value['sequence'] < 2**63 - 1, 'Ready sequence')
    require(str(uuid.UUID(value['membershipEpoch'])) == value['membershipEpoch'], 'Canonical epoch')
    ready = value['ready']
    require(type(ready) is dict and set(ready) == {'identity', 'rank', 'profile', 'executionPlanSHA256', 'requestCapacityBytes'}, 'Ready fields')
    require(type(ready['rank']) is int and ready['rank'] in (0, 1), 'Ready rank')
    require(type(ready['requestCapacityBytes']) is int and 1 <= ready['requestCapacityBytes'] <= 1 << 50, 'Capacity placeholder bound')
    identity = ready['identity']
    require(type(identity) is dict and set(identity) == {'membershipEpoch', 'modelID', 'artifactSHA256', 'configurationSHA256', 'peers'}, 'Identity fields')
    require(identity['membershipEpoch'] == value['membershipEpoch'] == '00000000-0000-0000-0000-000000000000', 'Owner zero-epoch template')
    profile = ready['profile']
    require(type(profile) is dict and set(profile) == {'id', 'vocabularySize', 'maximumPromptTokens', 'maximumOutputTokens', 'maximumChunkTokens', 'maximumContextTokens'}, 'Profile fields')
    require(type(identity['peers']) is list and len(identity['peers']) == 2, 'Two peers')
    hashes = [identity['artifactSHA256'], identity['configurationSHA256'], ready['executionPlanSHA256']]
    for peer in identity['peers']:
        require(type(peer) is dict and set(peer) == {'id', 'buildSHA256'}, 'Peer fields')
        hashes.append(peer['buildSHA256'])
    require(all(type(x) is str and re.fullmatch('[0-9a-f]{64}', x) for x in hashes), 'Hash syntax')
    return raw, value


def configuration(raw, controller):
    require(0 < len(raw) <= (500_000 if controller else 16_384), 'Outer file bound')
    value = framed(raw, 512*1024, append_missing=True)
    require(type(value) is dict and set(value) == (CONTROLLER if controller else OWNER), 'Outer configuration fields')
    template_raw, template = ready_template(value['readyTemplateBase64'])
    return value, template_raw, template


def check_paths(paths):
    rows, values = [], []
    for index, path in enumerate(paths):
        raw = Path(path).read_bytes()
        value, template_raw, template = configuration(raw, index == 0)
        require(template['ready']['rank'] == (0 if index < 2 else 1), 'Controller/rank mapping')
        values.append((value, template_raw, template))
        rows.append({'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                     'outerLFCount': raw.count(b'\n'), 'templateBytes': len(template_raw),
                     'templateSHA256': hashlib.sha256(template_raw).hexdigest(), 'templateLFCount': template_raw.count(b'\n')})
    require(values[0][1] == values[1][1], 'Controller and rank0 template must be identical')
    for key in ('identity', 'profile', 'executionPlanSHA256'):
        require(values[1][2]['ready'][key] == values[2][2]['ready'][key], 'Rank templates disagree')
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    for name in ('controller', 'owner-rank0', 'owner-rank1'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    print(json.dumps({'passed': True, 'files': check_paths([args.controller, args.owner_rank0, args.owner_rank1]),
                      'swiftDecoderExecuted': False, 'modelCompilerOrNetworkExecuted': False}, indent=2))


if __name__ == '__main__':
    main()
