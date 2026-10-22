"""Composite fabricated execution packet. No native process or tensor payloads."""
import base64
import copy
import json
from pathlib import Path
from binding_common import canonical, sha
from binding_manifests import REQUIRED_SOURCES
from binding_oracle import load
from binding_parent import schema
from binding_pins import PRIVATE_SOURCES, PRIVATE_SOURCE_PINS, SUPPORTED_NATIVE_SOURCE_PINS
from numeric_test_support import numeric_fixture, raw, TOKENS, PROMPT, TEACHER
from test_runtime_binding import runtime

REPOSITORY = Path('/Users/developer/DarkbloomDev/d-inference')
RESEARCH = REPOSITORY.parent / 'cluster-research'
RETAINED = REPOSITORY / 'experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json'
TEMPLATES = {}


class PacketFixture:
    def __init__(self, folder, profile='registered_qwen35_9b', reused=False, run_root='/invented/run', pid=73):
        self.folder, self.profile = Path(folder), profile
        self.folder.mkdir(exist_ok=True)
        self.oracle, self.contract = load()
        if profile not in TEMPLATES:
            TEMPLATES[profile] = numeric_fixture(profile)
        self.rows = copy.deepcopy(TEMPLATES[profile])
        actual_bundle = '/invented/retained/bundle' if reused else run_root + '/bundle'
        observed = runtime(actual_bundle)
        observed['processID'] = pid
        self.rows[0]['runtime'] = copy.deepcopy(observed)
        self.rows[1]['pair']['runtime'] = copy.deepcopy(observed)
        paths = sorted(REQUIRED_SOURCES | set(SUPPORTED_NATIVE_SOURCE_PINS))
        self.source = dict(schema_version=1, repository='/invented/repository',
                           dependencies=dict(repository_head='0'*40, submodules='', tracked_dependency_changes=''),
                           files=[])
        self.source_refs, self.bundle_refs, self.private_refs = [], [], []
        for index, name in enumerate(paths):
            data = (REPOSITORY / name).read_bytes()
            self.source['files'].append(dict(path=name, size_bytes=len(data), sha256=sha(data)))
            file = self.folder / f'source-{index}.bin';file.write_bytes(data)
            self.source_refs.append(dict(member=name, path=file.name))
        self.bundle = dict(schema_version=1, files=[])
        payloads = {'cluster-inference':b'invented executable bytes; never launched',
                    'mlx.metallib':b'invented metal library bytes; never loaded',
                    'rank_worker.py':(REPOSITORY / 'experiments/cluster/runtime/rank_worker.py').read_bytes(),
                    'artifacts.py':(REPOSITORY / 'experiments/cluster/runtime/artifacts.py').read_bytes()}
        for index, (name, data) in enumerate(payloads.items()):
            self.bundle['files'].append(dict(path=name, size_bytes=len(data), sha256=sha(data)))
            file = self.folder / f'bundle-{index}.bin';file.write_bytes(data)
            self.bundle_refs.append(dict(member=name, path=file.name))
        for index, (name, entry) in enumerate(PRIVATE_SOURCES.items()):
            data = (RESEARCH / 'registered-dense-short-parity-parent-draft' / name).read_bytes()
            assert sha(data) == entry['sha256']
            file = self.folder / f'private-{index}.txt';file.write_bytes(data)
            self.private_refs.append(dict(member=name, path=file.name))
        self.parent = copy.deepcopy(schema()['exactTypedValuesForBothBranches'])
        p = self.contract.PROFILES[profile]
        self.parent.update(registeredProfile=profile, expectedIdentity=p,
                           maximumSampledNativeRSSBytes=p['maximumSampledRSSBytes'],
                           nativePID=pid, privateSourceSHA256=PRIVATE_SOURCE_PINS,
                           expectedNativeSHA256=sha(payloads['cluster-inference']),
                           runtime='/invented/repository/experiments/cluster/runtime',
                           release='/invented/release', modelDirectory='/invented/model',
                           promptFile='/invented/original/prompt.json', teacherFile='/invented/original/teacher.json',
                           startedAtUTC='2026-09-14T00:00:00+00:00', finishedAtUTC='2026-09-14T00:00:01+00:00',
                           sourceFileCount=len(paths), bundleAcquisition='reused_external_reference' if reused else 'fresh_snapshot',
                           bundleCopiedForThisRun=not reused, rawTokenInputs=TOKENS,
                           expectedPromptSHA256=sha(PROMPT), expectedTeacherSHA256=sha(TEACHER))
        item = json.loads(RETAINED.read_bytes())['nine' if profile == 'registered_qwen35_9b' else 'twentySeven']
        self.parent['rawMetadataPins'] = {name:dict(sizeBytes=len(base64.b64decode(item[key])), sha256=p[key])
                                          for name,key in [('config.json','configuration'),('manifest.json','manifest')]}
        self.parent['command'] = self.contract.native_command(run_root+'/bundle/cluster-inference', '/invented/model', profile,
                                                              run_root+'/prompt.json', run_root+'/teacher.json', sha(PROMPT), sha(TEACHER))
        self.parent['memorySamples'] = [self.sample(i) for i in range(3)]
        self.parent['powerObservations'] = [self.power() for _ in range(3)]
        self.core = dict(stdout=raw(self.rows), stderr=b'', prompt=PROMPT, teacher=TEACHER,
                         retained_metadata=RETAINED.read_bytes())
        if reused:
            self.parent.update(bundleReferenceHelperSHA256=PRIVATE_SOURCE_PINS['owned_bundle_reference.py'],
                               bundleReference=dict(kind='owned_read_only_bundle_reference',schemaVersion=1,
                                                    requestedPath='/invented/input-alias', resolvedPath=actual_bundle,copied=False,
                                                    verifiedFileCount=4, expectedNativeSHA256=self.parent['expectedNativeSHA256'],
                                                    runtimeFilesSHA256={k:sha(payloads[k]) for k in ('rank_worker.py','artifacts.py')}))
        self.refresh_native()

    @staticmethod
    def sample(index):
        return dict(timestampUTC='2026-09-14T00:00:00+00:00', monotonicSeconds=float(index), pressureLevel=0,
                    reportedSwapBytes='0', actualFreeBytes=12*1024**3, rawMemory='invented no-swap source',
                    rawVMStat='invented free-page source', nativeRSSBytes=None, missingRSSIsNotZero=True)

    @staticmethod
    def power():
        return dict(timestampUTC='2026-09-14T00:00:00+00:00', raw="Now drawing from 'AC Power'\n",
                    admission=dict(source='AC Power', batteryPercent=None, batteryFloorApplied=False))

    def refresh_native(self):
        self.core['stdout'] = raw(self.rows)
        self.parent.update(self.contract.validate_result(self.core['stdout'], self.profile, TOKENS))
        self.core['numerical'] = canonical(self.oracle.audit(self.core['stdout'], self.profile, TOKENS)) + b'\n'
        for role,key in [('stdout','stdout.jsonl'),('stderr','stderr.log')]:
            data = self.core[role]
            self.parent[key] = dict(sizeBytes=len(data), sha256=sha(data), hashOmittedBecauseOversized=False)
        self.refresh_manifests()

    def refresh_manifests(self):
        self.core['source_manifest'] = canonical(self.source) + b'\n'
        self.core['bundle_manifest'] = canonical(self.bundle) + b'\n'
        self.parent['sourceManifestSHA256'] = sha(self.core['source_manifest'])
        self.parent['bundleManifestSHA256'] = sha(self.core['bundle_manifest'])
        if 'bundleReference' in self.parent:
            self.parent['bundleReference']['manifestSHA256'] = self.parent['bundleManifestSHA256']
        return self.publish()

    def publish(self):
        self.core['parent'] = canonical(self.parent) + b'\n'
        refs = {}
        for name,data in self.core.items():
            filename = name + '.json'
            (self.folder / filename).write_bytes(data)
            refs[name] = dict(path=filename, sha256=sha(data))
        self.packet = dict(schema='private_short_execution_binding_packet_v1', profile=self.profile, files=refs,
                           source_files=self.source_refs, bundle_files=self.bundle_refs, private_files=self.private_refs)
        self.path = self.folder / 'packet.json'
        self.path.write_bytes(canonical(self.packet)+b'\n')
        return self.path
