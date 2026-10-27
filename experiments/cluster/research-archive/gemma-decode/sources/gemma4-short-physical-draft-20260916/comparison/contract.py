"""Closed Gemma P32/C16/O2 prospective identity and bounded file inputs."""
from pathlib import Path
import re
import uuid
from recorded_math import canonical, digest, equal, flags, integer, parse_json, require, sha_string
from snapshot import snapshot

VOCABULARY = 262_144
MODES = ('full', 'stage0', 'stage1')
TARGETS = ('full-reference', 'stage-0', 'stage-1')
GLOBALS = (list(range(30)), list(range(10)), list(range(10, 30)))
SELECTED_COUNTS = (1339, 450, 892)
FLOATS = ('float16', 'bfloat16', 'float32')
ARTIFACT = '2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
CONFIGURATION = '29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa'
MANIFEST = 'c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd'


def fields(value, names):
    require(type(value) is dict and set(value) == set(names.split()), 'Unexpected object fields')


def bounded(value, minimum, maximum):
    require(integer(value, minimum) <= maximum, 'Integer exceeds closed bound')
    return value


def token_hash(tokens):
    require(type(tokens) is list, 'Token list required')
    for token in tokens: bounded(token, 0, VOCABULARY-1)
    return digest(','.join(map(str, tokens)).encode())


def text_hash(lines, separator='\n'):
    return digest(separator.join(map(str, lines)).encode())


def canonical_path(name, directory=False):
    require(type(name) is str and 0 < len(name.encode()) <= 4096, 'Invalid evidence path')
    path = Path(name)
    require(path.is_absolute() and path.resolve() == path and not path.is_symlink(), 'Noncanonical evidence path')
    require(path.is_dir() if directory else path.is_file(), 'Evidence path kind differs')
    return path


def pinned(reference, maximum):
    fields(reference, 'path sha256')
    path = canonical_path(reference['path'])
    before = path.lstat()
    result = snapshot(path, maximum)
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(result['identity'] == stamp(before) == stamp(path.lstat()), 'Evidence path replaced')
    equal(result['sha256'], sha_string(reference['sha256']), 'Pinned input digest differs')
    return result


def expected_description(value, prompt_raw):
    fields(value, 'schema scopeSHA256 membershipEpoch buildIdentitySHA256 requestID requestSHA256 promptFileSHA256 promptTokenIDsSHA256 profile planSHA256 stageSHA256 mappingSHA256 targets artifactSHA256 configurationSHA256 manifestSHA256 cut promptCount chunkSize outputCount maximumTokens finalFrontier stopTokenIDs metadataOnly actualPayloadLoaded actualKVTypeObserved buildIdentityRequiresParentVerification runtimeExecutionAuthorized')
    for key in ('membershipEpoch', 'requestID'):
        require(type(value[key]) is str and str(uuid.UUID(value[key])) == value[key], 'Noncanonical UUID')
    for key in ('scopeSHA256','buildIdentitySHA256','requestSHA256','promptFileSHA256','promptTokenIDsSHA256','planSHA256','mappingSHA256'):
        sha_string(value[key])
    equal(value['stageSHA256'], [sha_string(x) for x in value['stageSHA256']], 'Stage digests')
    require(len(value['stageSHA256']) == 2 and len(set(value['stageSHA256'])) == 2, 'Two distinct stages')
    for key,wanted in dict(schema='gemma4_short_expected_v1',artifactSHA256=ARTIFACT,
        configurationSHA256=CONFIGURATION,manifestSHA256=MANIFEST,cut=10,promptCount=32,
        chunkSize=16,outputCount=2,maximumTokens=34,finalFrontier=33,stopTokenIDs=[]).items():
        equal(value[key], wanted, 'Expected scope differs: '+key)
    flags(value,metadataOnly=True,actualPayloadLoaded=False,actualKVTypeObserved=False,
          buildIdentityRequiresParentVerification=True,runtimeExecutionAuthorized=False)
    require(0 < len(prompt_raw) <= 4096, 'Prompt byte bound')
    tokens = parse_json(prompt_raw)
    require(type(tokens) is list and len(tokens)==32, 'Exactly 32 prompt IDs')
    equal(digest(prompt_raw), value['promptFileSHA256'], 'Prospective prompt file digest')
    equal(token_hash(tokens), value['promptTokenIDsSHA256'], 'Prompt token identity')
    p = value['profile']
    fields(p, 'identifier vocabularySize hiddenSize activationDType maximumPromptTokens maximumChunkTokens maximumOutputTokens maximumContextTokens fingerprint')
    require(p['activationDType'] in FLOATS, 'Unknown activation dtype')
    profile = dict(identifier='registered_gemma4_26b_forward_validation_v1',vocabularySize=VOCABULARY,
        hiddenSize=2816,activationDType=p['activationDType'],maximumPromptTokens=8192,
        maximumChunkTokens=512,maximumOutputTokens=128,maximumContextTokens=8320)
    profile['fingerprint'] = text_hash(['qwen-stage-generation-profile-v1']+list(profile.values()), '|')
    equal(p, profile, 'Exact Gemma profile/fingerprint')
    request_hash = text_hash(['qwen-stage-generation-request-v1',p['fingerprint'],value['requestID'],
        'prompt='+token_hash(tokens),'chunk=16','output=2','stop='])
    equal(value['requestSHA256'], request_hash, 'Request fingerprint')
    equal(value['scopeSHA256'], text_hash(['gemma4-short-correctness-v1',value['membershipEpoch'],
        value['buildIdentitySHA256'],value['planSHA256'],request_hash,value['promptFileSHA256'],
        'exact-bytes-before-any-numerical-qualification','mtp=false','cut=10']), 'Scope fingerprint')
    require(type(value['targets']) is list and len(value['targets'])==3, 'Complete three-target description')
    for index,target in enumerate(value['targets']):
        fields(target, 'name parameterLayoutSHA256 selectedTensorCount selectedBytes globalLayerIndices')
        equal(target['name'], TARGETS[index], 'Target order')
        equal(target['globalLayerIndices'], GLOBALS[index], 'Target global ownership')
        equal(target['selectedTensorCount'], SELECTED_COUNTS[index], 'Exact selected tensor count')
        bounded(target['selectedBytes'], 1, 14_467_688_508)
        sha_string(target['parameterLayoutSHA256'])
    equal(value['targets'][0]['selectedBytes'], 14_467_688_508, 'Exact full text tensor bytes')
    return tokens


class Sidecars:
    def __init__(self, directory, files):
        self.directory = canonical_path(directory, directory=True)
        require(type(files) is list and 1 <= len(files) <= 128, 'Sidecar count bound')
        self.files = {}
        total = 0
        for item in files:
            fields(item, 'name bytes sha256')
            name = item['name']
            require(type(name) is str and re.fullmatch('[a-z0-9][a-z0-9._-]{0,127}',name)
                    and name not in self.files, 'Invalid/duplicate sidecar name')
            total += bounded(item['bytes'],1,16_777_216)
            sha_string(item['sha256']); self.files[name]=item
        require(total <= 33_554_432, 'Total native sidecar bound')
        self.directory_identity = (self.directory.stat().st_dev,self.directory.stat().st_ino)
        names = list(self.directory.iterdir())
        require(all(p.is_file() and not p.is_symlink() for p in names), 'Unexpected sidecar path kind')
        equal(sorted(p.name for p in names),sorted(self.files),'Sidecar directory closure')
        self.reads = {}

    def read(self, file):
        equal(self.files.get(file['name']),file,'Sidecar receipt differs')
        require(file['name'] not in self.reads,'Sidecar consumed twice')
        result = pinned(dict(path=str(self.directory/file['name']),sha256=file['sha256']),file['bytes'])
        equal(result['size_bytes'],file['bytes'],'Sidecar byte count')
        self.reads[file['name']] = dict(bytes=result['size_bytes'],sha256=result['sha256'])
        return result['raw']

    def finish(self):
        equal(sorted(self.reads),sorted(self.files),'Unconsumed sidecar')
        equal((self.directory.stat().st_dev,self.directory.stat().st_ino),self.directory_identity,'Sidecar directory replaced')
        equal(sorted(p.name for p in self.directory.iterdir()),sorted(self.files),'Sidecar closure changed')
        return self.reads
