#!/usr/bin/env python3
"""Actual runner/curator subprocess regressions using a harmless CPU child."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
RUNNER = ROOT / "run_suite.py"
CURATOR = ROOT / "curate_runs.py"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


CHILD = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys,time
args=sys.argv[1:]
def option(name):return args[args.index(name)+1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
config=pathlib.Path(option('--config'))
original=pathlib.Path(ORIGINAL_CONFIG)
original_bytes=None
if original.with_suffix('.mutate-before-read').exists():
    original_bytes=original.read_bytes()
    changed=json.loads(original_bytes)
    changed['backend']='contiguous'
    original.write_text(json.dumps(changed))
source_hash=sha(original)
try:
    config_bytes=config.read_bytes()
finally:
    if original_bytes is not None:original.write_bytes(original_bytes)
settings=json.loads(config_bytes)
if settings.get('relativeCache'):
    assert (config.parent/settings['relativeCache']).is_dir()
with pathlib.Path(settings['marker']).open('a') as f:f.write(option('--kv-quantization')+'\n')
if settings.get('sleep'):time.sleep(settings['sleep'])
if settings.get('badJSON'):
    print('failed before a report');sys.exit(2)
score='--teacher-forced-input' in args
path=pathlib.Path(option('--teacher-forced-input' if score else '--runtime-prompt-file'))
document=json.loads(path.read_text()) if score else json.loads((path.parent/(option('--model')+'-scores-input.json')).read_text())
report={'verifiedModelAggregateSHA256':document['expectedModelAggregateSHA256'],
        'resolvedBackend':settings.get('backend','paged'),'kvQuantization':option('--kv-quantization'),
        'firstTokenMilliseconds':12.5,'totalMilliseconds':25.0,
        'observedEnvironment':dict(os.environ),'configPath':str(config.absolute()),
        'configSHA256':hashlib.sha256(config_bytes).hexdigest(),'configMode':config.stat().st_mode & 0o777,
        'sourceConfigDuringReadSHA256':source_hash,'workingDirectory':str(pathlib.Path.cwd()),
        'modelCachePath':str((config.parent/settings['relativeCache']).resolve())}
resource=pathlib.Path(sys.argv[0]).parent/'ProviderCore.bundle'/'shader.metal'
report['resourceSHA256']=sha(resource)
if '--runtime-assistant-directory' in args:
    assistant=pathlib.Path(option('--runtime-assistant-directory'))
    source_weight=original.parent.parent/'assistant'/'weights.safetensors'
    source_bytes=source_weight.read_bytes()
    if settings.get('mutateAssistantBeforeRead'):source_weight.write_bytes(source_bytes+b' changed')
    source_assistant_hash=sha(source_weight)
    try:
        files={p.name:sha(p) for p in sorted(assistant.iterdir())}
    finally:
        if settings.get('mutateAssistantBeforeRead'):source_weight.write_bytes(source_bytes)
    identity={'source':'local','revision':'local-'+files['config.json'][:16],
              'config_sha256':files['config.json']}
    identity.update({'weight_sha256.'+name:value for name,value in files.items() if name!='config.json'})
    if settings.get('inlineAssistant'):
        config_hash=('d' if settings.get('assistantIdentityDrift') and option('--kv-quantization')!='native' else 'a')*64
        identity={'source':'inline','revision':'inline-'+config_hash[:8]+'-'+'b'*8,
                  'config_sha256':config_hash,'inline_index_sha256':'b'*64}
    elif settings.get('assistantIdentityDrift') and option('--kv-quantization')!='native':
        identity['weight_sha256.weights.safetensors']='f'*64
    report.update(mtpRequested=True,mtpActive=not settings.get('inactiveAssistant',False),assistantIdentity=identity,
                  assistantPath=str(assistant),assistantFiles=files,sourceAssistantDuringReadSHA256=source_assistant_hash,
                  assistantDirectoryMode=assistant.stat().st_mode & 0o777,
                  assistantModes={p.name:p.stat().st_mode & 0o777 for p in assistant.iterdir()},
                  assistantSymlinks=[p.name for p in assistant.iterdir() if p.is_symlink()])
elif '--runtime-mtp' in args:
    config_hash=hashlib.sha256(option('--model').encode()).hexdigest()
    if settings.get('assistantIdentityDrift') and option('--kv-quantization')!='native':config_hash='d'*64
    report.update(mtpRequested=True,mtpActive=True,
                  assistantIdentity={'source':'inline','revision':'inline-'+config_hash[:8]+'-'+'b'*8,
                                     'config_sha256':config_hash,'inline_index_sha256':'b'*64})
fault=settings.get('assistantIdentityFault')
if fault=='missing':report.pop('assistantIdentity',None)
if fault=='type':report['assistantIdentity']='inline'
if fault=='none':report['assistantIdentity']={'source':'none'}
if fault=='config_hash':report['assistantIdentity']['config_sha256']='g'*64
if fault=='index_hash':report['assistantIdentity']['inline_index_sha256']=None
if fault=='revision':report['assistantIdentity']['revision']='unbound'
if fault=='inactive':report['mtpActive']=False
if fault=='not_requested':report['mtpRequested']=False
if fault=='local':report['assistantIdentity']={'source':'local','revision':'local-'+'a'*16,'config_sha256':'a'*64,
                                            'weight_sha256.weights.safetensors':'b'*64}
binary=sha(pathlib.Path(sys.argv[0]));metal=sha(pathlib.Path(sys.argv[0]).parent/'mlx.metallib')
if score:
    diagnostic={'records':[{'nanCount':0,'infiniteCount':0}],'top1':[3]}
    report.update(executableSHA256=binary,metallibSHA256=metal,input=document,
                  inputSHA256=settings.get('scoreHash',sha(path)),diagnostic=diagnostic,
                  repeatedDiagnostic=diagnostic,plainTop1=[3],meanForcedTokenNLL=1.25)
else:
    answer={'answer':'wrong' if settings.get('wrongAnswer') else 'contaminated' if 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK' in os.environ else 'ok'}
    report.update(runtimeIdentity={'binary_sha256':binary,'metallib_sha256':metal},
                  promptSHA256=settings.get('promptHash',sha(path)),
                  renderDate=settings.get('date',option('--runtime-prompt-date')),
                  finishReason=settings.get('finishReason','stop'),text=settings.get('outputText',json.dumps(answer)))
if settings.get('mutateInput'):path.write_text(path.read_text()+' ')
if settings.get('mutateConfig'):original.write_text(original.read_text()+' ')
if settings.get('mutateSnapshot'):
    config.chmod(0o600)
    config.write_text(config.read_text()+' ')
if settings.get('mutateAssistant'):source_weight.write_bytes(source_weight.read_bytes()+b' changed')
if settings.get('mutateAssistantSnapshot'):
    assistant.chmod(0o700)
    weight=assistant/'weights.safetensors'
    weight.chmod(0o600)
    weight.write_bytes(weight.read_bytes()+b' changed')
if settings.get('resourceMutation')=='edit':resource.write_text('changed resource')
if settings.get('resourceMutation')=='add':(resource.parent/'new.metal').write_text('unbound resource')
if settings.get('resourceMutation')=='remove':resource.unlink()
print(json.dumps(report))
'''


class Fixture:
    def __init__(self, root, settings=None):
        self.root = root
        self.candidate = root / "candidate"
        self.inputs = root / "prepared"
        self.stage = root / "stage"
        self.config = root / "config" / "provider.toml"
        self.assistant = root / "assistant"
        self.marker = root / "child-called"
        self.candidate.mkdir()
        self.inputs.mkdir()
        self.config.parent.mkdir()
        (root / "relative-models").mkdir()
        self.config.write_text(json.dumps(dict(marker=str(self.marker), relativeCache="../relative-models", **(settings or {}))))
        binary = self.candidate / "darkbloom"
        binary.write_text(CHILD.replace("ORIGINAL_CONFIG", repr(str(self.config))))
        binary.chmod(0o755)
        metal = self.candidate / "mlx.metallib"
        metal.write_text("CPU fixture only; not a GPU artifact\n")
        self.resource = self.candidate / "ProviderCore.bundle" / "shader.metal"
        self.resource.parent.mkdir()
        self.resource.write_text("CPU fixture resource; not a Metal program\n")
        self.resources = {str(self.resource.relative_to(self.candidate)): digest(self.resource)}
        self.artifacts = {"darkbloom": digest(binary), "mlx.metallib": digest(metal)}
        (self.candidate / "source-receipt.json").write_text(json.dumps({
            "source_file_digest": "fixture-source", "artifacts": self.artifacts, "resources": self.resources}))
        self.prompt = self.inputs / "retrieval.txt"
        self.prompt.write_text("Public synthetic task\n")
        self.score = self.inputs / "fixture-scores-input.json"
        self.score.write_text(json.dumps({"modelID": "fixture", "expectedModelAggregateSHA256": "c" * 64,
                                          "promptTokens": [1, 2], "continuation": [3]}))
        (self.inputs / "suite.json").write_text(json.dumps({
            "schema": 1, "renderDate": "2026-10-09",
            "tasks": [{"id": "retrieval", "file": self.prompt.name, "promptSHA256": digest(self.prompt),
                       "maximumGeneratedTokens": 8, "expected": {"answer": "ok"}}],
            "scoreInputs": [{"modelID": "fixture", "file": self.score.name, "inputSHA256": digest(self.score),
                             "promptTokenCount": 2, "continuationTokenCount": 1}]}))

    def make_assistant(self, symlinks=False):
        self.assistant.mkdir()
        contents = {"config.json": b'{"model_type":"public_cpu_fixture"}',
                    "weights.safetensors": b"Public CPU fixture; not real model weights\n"}
        if symlinks:
            blobs = self.root / "blobs"
            blobs.mkdir()
        for name, data in contents.items():
            path = self.assistant / name
            if symlinks:
                target = blobs / name
                target.write_bytes(data)
                path.symlink_to(Path("../blobs") / name)
            else:
                path.write_bytes(data)
        return {name: digest(self.assistant / name) for name in contents}

    def run(self, scores=False, environment=None, config=None, profiles=None, timeout=10, cwd=None,
            mtp=False, assistant=None, models=None):
        command = [sys.executable, str(RUNNER), "--candidate", str(self.candidate),
                   "--config", str(self.config if config is None else config),
                   "--inputs", str(self.inputs), "--output", str(self.stage),
                   "--models", *(models or ["fixture"]), "--tasks", "none" if scores else "retrieval", "--timeout", str(timeout)]
        if scores:
            command.append("--scores")
        if profiles is not None:
            command += ["--profiles", *profiles]
        if mtp:
            command.append("--mtp")
        if assistant is not None:
            command += ["--assistant-directory", str(assistant)]
        result = subprocess.run(command, env=environment, cwd=cwd, capture_output=True, text=True, timeout=15)
        manifest = self.stage / "run.json"
        return result, json.loads(manifest.read_text()) if manifest.exists() else None

    def curate(self, inputs=False):
        command = [sys.executable, str(CURATOR), "--root", str(self.root), "--stages", "stage",
                   "--output", str(self.root / "curated.json")]
        if inputs:
            command += ["--inputs", str(self.inputs)]
        return subprocess.run(command, capture_output=True, text=True, timeout=10)

    def mutate_report(self, mode, transform):
        manifest = json.loads((self.stage / "run.json").read_text())
        for entry in manifest["results"]:
            raw = self.stage / ("fixture-" + mode + "-" + entry["requestedPrecision"] + ".json")
            report = json.loads(raw.read_text())
            transform(report)
            raw.write_text(json.dumps(report))
            entry["jsonSHA256"] = digest(raw)
        (self.stage / "run.json").write_text(json.dumps(manifest))

    def report_path(self, entry):
        label = entry["modelID"].replace("/", "--") + "-" + entry["mode"] + "-" + entry["requestedPrecision"]
        if "--runtime-mtp" in entry["command"]:
            label += "-mtp"
        return self.stage / (label + ".json")


class QualificationRunnerContractTests(unittest.TestCase):
    def test_actual_children_are_scrubbed_and_input_config_receipts_curate(self):
        for scores in (False, True):
            with self.subTest(scores=scores), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                original = fixture.config.read_bytes()
                original_mode = fixture.config.stat().st_mode
                environment = dict(os.environ, DARKBLOOM_CBV2_ATTN_QUERY_BLOCK="1",
                                   DARKBLOOM_CBV2_KV_QUANTIZATION="k8v8", MLX_TEST_OVERRIDE="1",
                                   DYLD_INSERT_LIBRARIES="/invalid", HF_TOKEN="never-forward-this", TZ="UTC")
                # DYLD would affect the Python runner itself on macOS; remove
                # it there and test a representative non-loader override.
                environment.pop("DYLD_INSERT_LIBRARIES")
                result, manifest = fixture.run(scores=scores, environment=environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(manifest["schema"], 2)
                self.assertEqual(len(manifest["results"]), 2)
                active_config = Path(manifest["qualification"]["activeConfigPath"])
                self.assertNotEqual(active_config, fixture.config)
                self.assertEqual(active_config.parent, fixture.config.parent.resolve())
                self.assertFalse(active_config.exists())
                self.assertEqual(fixture.config.read_bytes(), original)
                self.assertEqual(fixture.config.stat().st_mode, original_mode)
                self.assertEqual((fixture.stage / "provider-config.toml").read_bytes(), original)
                for entry in manifest["results"]:
                    self.assertTrue(entry["identityPassed"])
                    self.assertEqual(entry["configBeforeSHA256"], digest(fixture.config))
                    self.assertEqual(entry["configAfterSHA256"], digest(fixture.config))
                    mode = "scores" if scores else "retrieval"
                    report = json.loads((fixture.stage / ("fixture-" + mode + "-" + entry["requestedPrecision"] + ".json")).read_text())
                    self.assertEqual(entry["command"][entry["command"].index("--config") + 1], str(active_config))
                    self.assertEqual(report["configPath"], str(active_config))
                    self.assertEqual(report["configSHA256"], manifest["qualification"]["configSHA256"])
                    self.assertEqual(report["configMode"], 0o400)
                    self.assertEqual(report["observedEnvironment"]["TZ"], "UTC")
                    for key in ("DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "DARKBLOOM_CBV2_KV_QUANTIZATION", "MLX_TEST_OVERRIDE", "HF_TOKEN"):
                        self.assertNotIn(key, report["observedEnvironment"])
                curated = fixture.curate()
                self.assertEqual(curated.returncode, 0, curated.stderr)

    def test_original_config_mutation_before_child_read_cannot_change_any_arm(self):
        for scores in (False, True):
            with self.subTest(scores=scores), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "suite with spaces"
                root.mkdir()
                fixture = Fixture(root)
                original = fixture.config.read_bytes()
                original_mode = fixture.config.stat().st_mode
                fixture.config.with_suffix(".mutate-before-read").touch()
                profiles = ["native", "balanced", "k8v4", "k8v8"]
                result, manifest = fixture.run(scores=scores, config=Path("config/provider.toml"),
                                               profiles=profiles, cwd=root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(fixture.config.read_bytes(), original)
                self.assertEqual(fixture.config.stat().st_mode, original_mode)
                self.assertEqual((fixture.stage / "provider-config.toml").read_bytes(), original)
                self.assertEqual(fixture.marker.read_text().splitlines(), profiles)
                self.assertEqual(len(manifest["results"]), len(profiles))
                active_config = Path(manifest["qualification"]["activeConfigPath"])
                self.assertEqual(active_config.parent, fixture.config.parent.resolve())
                self.assertFalse(active_config.exists())
                for entry in manifest["results"]:
                    self.assertTrue(entry["reportParsed"])
                    mode = "scores" if scores else "retrieval"
                    report = json.loads((fixture.stage / ("fixture-" + mode + "-" + entry["requestedPrecision"] + ".json")).read_text())
                    self.assertEqual(report["configPath"], str(active_config))
                    self.assertEqual(report["configMode"], 0o400)
                    self.assertEqual(report["configSHA256"], digest(fixture.config))
                    self.assertNotEqual(report["sourceConfigDuringReadSHA256"], digest(fixture.config))
                    self.assertEqual(report["resolvedBackend"], "paged")
                    self.assertEqual(report["workingDirectory"], str(root.resolve()))
                    self.assertEqual(report["modelCachePath"], str((root / "relative-models").resolve()))

    def test_symlink_config_preserves_lexical_parent_for_relative_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            target = fixture.root / "detached" / "nested" / "provider.toml"
            target.parent.mkdir(parents=True)
            fixture.config.rename(target)
            fixture.config.symlink_to(target)
            original = target.read_bytes()
            result, manifest = fixture.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(fixture.config.is_symlink())
            self.assertEqual(target.read_bytes(), original)
            active_config = Path(manifest["qualification"]["activeConfigPath"])
            self.assertEqual(active_config.parent, fixture.config.parent.resolve())
            self.assertFalse(active_config.exists())
            self.assertFalse(list(fixture.config.parent.glob(".qualification-*.toml")))
            for entry in manifest["results"]:
                report = json.loads((fixture.stage / ("fixture-retrieval-" + entry["requestedPrecision"] + ".json")).read_text())
                self.assertEqual(report["configPath"], str(active_config))
                self.assertEqual(report["modelCachePath"], str((fixture.root / "relative-models").resolve()))

    def test_config_snapshot_cleanup_on_launch_failure_and_timeout(self):
        for failure in ("launch_failed", "timeout"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {"sleep": 60} if failure == "timeout" else None)
                original = fixture.config.read_bytes()
                if failure == "launch_failed":
                    (fixture.candidate / "darkbloom").chmod(0o644)
                result, manifest = fixture.run(profiles=["native"], timeout=1)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(manifest["results"]), 1)
                self.assertEqual(manifest["results"][0]["exitCode"], failure)
                self.assertFalse(manifest["results"][0]["reportParsed"])
                self.assertEqual(fixture.config.read_bytes(), original)
                self.assertEqual((fixture.stage / "provider-config.toml").read_bytes(), original)
                self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())
                self.assertFalse(list(fixture.config.parent.glob(".qualification-*.toml")))

    def test_assistant_snapshot_dereferences_hf_links_and_binds_every_arm(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "suite with spaces"
            root.mkdir()
            fixture = Fixture(root, {"mutateAssistantBeforeRead": True})
            files = fixture.make_assistant(symlinks=True)
            result, manifest = fixture.run(mtp=True, assistant=Path("assistant"), cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)
            binding = manifest["qualification"]["assistant"]
            self.assertEqual(binding["files"], files)
            snapshot = Path(binding["path"])
            self.assertNotEqual(snapshot, fixture.assistant)
            self.assertFalse(snapshot.exists())
            self.assertFalse(list(fixture.stage.glob(".assistant-*")))
            self.assertTrue((fixture.assistant / "weights.safetensors").is_symlink())
            self.assertEqual(digest(fixture.assistant / "weights.safetensors"), files["weights.safetensors"])
            self.assertEqual(len(manifest["results"]), 2)
            for entry in manifest["results"]:
                report = json.loads(fixture.report_path(entry).read_text())
                self.assertEqual(report["assistantPath"], str(snapshot))
                self.assertEqual(report["assistantFiles"], files)
                self.assertEqual(report["assistantDirectoryMode"], 0o500)
                self.assertEqual(set(report["assistantModes"].values()), {0o400})
                self.assertEqual(report["assistantSymlinks"], [])
                self.assertNotEqual(report["sourceAssistantDuringReadSHA256"], files["weights.safetensors"])
                self.assertEqual(report["assistantIdentity"], binding["identities"]["fixture"])
                self.assertEqual(entry["command"][entry["command"].index("--runtime-assistant-directory") + 1], str(snapshot))
            self.assertEqual(fixture.curate().returncode, 0)

    def test_assistant_source_and_snapshot_drift_are_retained_and_stop_next_arm(self):
        for setting in ("mutateAssistant", "mutateAssistantSnapshot"):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {setting: True})
                fixture.make_assistant()
                result, manifest = fixture.run(mtp=True, assistant=fixture.assistant)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(manifest["results"]), 1)
                self.assertFalse(manifest["results"][0]["reportParsed"])
                self.assertIn("Assistant", manifest["results"][0]["parseError"])
                self.assertEqual(fixture.marker.read_text().splitlines(), ["native"])
                self.assertFalse(Path(manifest["qualification"]["assistant"]["path"]).exists())
                self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())

    def test_reported_assistant_identity_must_match_snapshot_or_stable_inline_identity(self):
        for inline, drift in ((False, True), (True, False), (True, True)):
            with self.subTest(inline=inline, drift=drift), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {"inlineAssistant": inline, "assistantIdentityDrift": drift})
                fixture.make_assistant()
                result, manifest = fixture.run(mtp=True, assistant=fixture.assistant)
                self.assertEqual(result.returncode == 0, not drift, result.stderr)
                self.assertTrue(manifest["results"][0]["reportParsed"])
                self.assertEqual(manifest["results"][1]["reportParsed"], not drift)
                self.assertEqual(fixture.curate().returncode, 0)

    def test_implicit_mtp_binds_stable_identities_per_model_without_claiming_a_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            second_score = fixture.inputs / "second-scores-input.json"
            document = json.loads(fixture.score.read_text())
            document.update(modelID="second", expectedModelAggregateSHA256="d" * 64)
            second_score.write_text(json.dumps(document))
            suite_path = fixture.inputs / "suite.json"
            suite = json.loads(suite_path.read_text())
            suite["scoreInputs"].append(dict(suite["scoreInputs"][0], modelID="second", file=second_score.name,
                                             inputSHA256=digest(second_score)))
            suite_path.write_text(json.dumps(suite))
            result, manifest = fixture.run(mtp=True, models=["fixture", "second"])
            self.assertEqual(result.returncode, 0, result.stderr)
            binding = manifest["qualification"]["assistant"]
            self.assertEqual(set(binding), {"identities"})
            self.assertEqual(set(binding["identities"]), {"fixture", "second"})
            self.assertNotEqual(binding["identities"]["fixture"], binding["identities"]["second"])
            self.assertEqual(len(manifest["results"]), 4)
            self.assertFalse(list(fixture.stage.glob(".assistant-*")))
            self.assertFalse(fixture.assistant.exists())
            self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())
            for entry in manifest["results"]:
                report = json.loads(fixture.report_path(entry).read_text())
                self.assertTrue(entry["reportParsed"])
                self.assertTrue(entry["identityPassed"])
                self.assertTrue(entry["taskPassed"])
                self.assertTrue(report["mtpRequested"])
                self.assertTrue(report["mtpActive"])
                self.assertEqual(report["assistantIdentity"], binding["identities"][entry["modelID"]])
                self.assertNotIn("--runtime-assistant-directory", entry["command"])
                self.assertEqual(entry["configAfterSHA256"], manifest["qualification"]["configSHA256"])
                self.assertEqual(report["resourceSHA256"], next(iter(fixture.resources.values())))
            curated = fixture.curate()
            self.assertEqual(curated.returncode, 0, curated.stderr)
            output = json.loads((fixture.root / "curated.json").read_text())
            self.assertEqual(output["stages"][0]["qualification"]["assistant"], binding)

    def test_implicit_mtp_drift_is_retained_and_cannot_be_promoted_by_curation(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), {"assistantIdentityDrift": True})
            result, manifest = fixture.run(mtp=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(len(manifest["results"]), 2)
            first, second = manifest["results"]
            self.assertTrue(first["reportParsed"])
            self.assertFalse(second["reportParsed"])
            self.assertIn("MTP assistant identity changed", second["parseError"])
            first_report = json.loads(fixture.report_path(first).read_text())
            second_report = json.loads(fixture.report_path(second).read_text())
            self.assertNotEqual(first_report["assistantIdentity"], second_report["assistantIdentity"])
            self.assertEqual(manifest["qualification"]["assistant"]["identities"]["fixture"],
                             first_report["assistantIdentity"])
            self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())
            self.assertEqual(fixture.curate().returncode, 0)
            for entry in manifest["results"]:
                entry.update(reportParsed=True, identityPassed=True, taskPassed=True)
            manifest["qualification"]["assistant"]["identities"]["fixture"] = second_report["assistantIdentity"]
            (fixture.stage / "run.json").write_text(json.dumps(manifest))
            curated = fixture.curate()
            self.assertNotEqual(curated.returncode, 0)
            self.assertIn("MTP assistant identity changed", curated.stderr)
            for entry in manifest["results"]:
                self.assertEqual(digest(fixture.report_path(entry)), entry["jsonSHA256"])

    def test_implicit_mtp_missing_invalid_and_inactive_identities_cannot_qualify(self):
        for fault in ("missing", "type", "none", "config_hash", "index_hash", "revision",
                      "inactive", "not_requested", "local"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {"assistantIdentityFault": fault})
                result, manifest = fixture.run(mtp=True, profiles=["native"])
                self.assertEqual(result.returncode, 1, result.stderr)
                entry = manifest["results"][0]
                self.assertFalse(entry["reportParsed"])
                self.assertNotIn("taskPassed", entry)
                self.assertEqual(manifest["qualification"]["assistant"], {"identities": {}})
                self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())
                self.assertEqual(fixture.curate().returncode, 0)
                entry.update(reportParsed=True, identityPassed=True, taskPassed=True)
                report = json.loads(fixture.report_path(entry).read_text())
                manifest["qualification"]["assistant"]["identities"]["fixture"] = report.get("assistantIdentity")
                (fixture.stage / "run.json").write_text(json.dumps(manifest))
                self.assertNotEqual(fixture.curate().returncode, 0)
                self.assertEqual(digest(fixture.report_path(entry)), entry["jsonSHA256"])

    def test_curator_requires_implicit_binding_and_matching_raw_mtp_request(self):
        for mutation in ("identity", "missing_binding", "hidden_request"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                result, manifest = fixture.run(mtp=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                if mutation == "identity":
                    manifest["qualification"]["assistant"]["identities"]["fixture"]["config_sha256"] = "f" * 64
                else:
                    del manifest["qualification"]["assistant"]
                    if mutation == "hidden_request":
                        for entry in manifest["results"]:
                            old = fixture.report_path(entry)
                            entry["command"].remove("--runtime-mtp")
                            new = fixture.report_path(entry)
                            old.rename(new)
                            old.with_suffix(".log").rename(new.with_suffix(".log"))
                (fixture.stage / "run.json").write_text(json.dumps(manifest))
                curated = fixture.curate()
                self.assertNotEqual(curated.returncode, 0)
                if mutation == "missing_binding":
                    self.assertIn("Missing run MTP assistant binding", curated.stderr)
                elif mutation == "hidden_request":
                    self.assertIn("Run MTP request differs from raw report", curated.stderr)
                for entry in manifest["results"]:
                    self.assertEqual(digest(fixture.report_path(entry)), entry["jsonSHA256"])

    def test_assistant_snapshot_cleanup_on_failed_and_timed_out_children(self):
        for setting, value in (("badJSON", True), ("sleep", 60), ("inactiveAssistant", True)):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {setting: value})
                fixture.make_assistant()
                result, manifest = fixture.run(mtp=True, assistant=fixture.assistant, profiles=["native"], timeout=1)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(manifest["results"][0]["reportParsed"])
                self.assertFalse(Path(manifest["qualification"]["assistant"]["path"]).exists())
                self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())

    def test_invalid_or_oversized_assistants_never_launch_or_leave_partial_copies(self):
        for invalid in ("directory", "broken_link", "oversized"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                fixture.make_assistant()
                weight = fixture.assistant / "weights.safetensors"
                if invalid == "directory":
                    (fixture.assistant / "nested.safetensors").mkdir()
                elif invalid == "broken_link":
                    weight.unlink()
                    weight.symlink_to("missing")
                else:
                    with weight.open("wb") as stream:
                        stream.truncate((2 << 30) + 1)
                result, _ = fixture.run(mtp=True, assistant=fixture.assistant)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(fixture.marker.exists())
                self.assertFalse(list(fixture.stage.glob(".assistant-*")))
                self.assertFalse(list(fixture.config.parent.glob(".qualification-*.toml")))

    def test_scores_do_not_snapshot_or_use_an_unrequested_assistant(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            result, manifest = fixture.run(scores=True, mtp=True, assistant=fixture.assistant)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("assistant", manifest["qualification"])
            for entry in manifest["results"]:
                self.assertNotIn("--runtime-assistant-directory", entry["command"])
                self.assertNotIn("--runtime-mtp", entry["command"])
            self.assertFalse(list(fixture.stage.glob(".assistant-*")))
            self.assertEqual(fixture.curate().returncode, 0)

    def test_full_resource_inventory_is_checked_before_and_after_every_arm(self):
        for when in ("before", "during"):
            for mutation in ("edit", "add", "remove"):
                with self.subTest(when=when, mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                    fixture = Fixture(Path(temporary), {"resourceMutation": mutation} if when == "during" else None)
                    if when == "before":
                        if mutation == "edit":
                            fixture.resource.write_text("changed resource")
                        elif mutation == "add":
                            (fixture.resource.parent / "new.metal").write_text("unbound resource")
                        else:
                            fixture.resource.unlink()
                    result, manifest = fixture.run()
                    self.assertNotEqual(result.returncode, 0)
                    if when == "before":
                        self.assertFalse(fixture.marker.exists())
                    else:
                        self.assertEqual(len(manifest["results"]), 1)
                        self.assertFalse(manifest["results"][0]["reportParsed"])
                        self.assertIn("resource inventory", manifest["results"][0]["parseError"])
                        self.assertEqual(fixture.marker.read_text().splitlines(), ["native"])
                        self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())

    def test_curator_rebuilds_bound_projections_from_unchanged_raw_reports(self):
        for scores in (False, True):
            with self.subTest(scores=scores), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {"wrongAnswer": not scores})
                result, manifest = fixture.run(scores=scores)
                self.assertEqual(result.returncode, 0 if scores else 1, result.stderr)
                raw = {str(fixture.report_path(entry)): fixture.report_path(entry).read_bytes()
                       for entry in manifest["results"]}
                for entry in manifest["results"]:
                    entry.update(taskPassed=True, answer={"answer": "ok"}, outputText="invented",
                                 identityPassed=False, meanForcedTokenNLL=-99.0, firstTokenMilliseconds=-99.0,
                                 resolvedBackend="contiguous", assistantIdentity={"source": "invented"},
                                 diagnosticChecks={"finiteLogits": False})
                (fixture.stage / "run.json").write_text(json.dumps(manifest))
                curated = fixture.curate()
                self.assertEqual(curated.returncode, 0, curated.stderr)
                for path, contents in raw.items():
                    self.assertEqual(Path(path).read_bytes(), contents)
                output = json.loads((fixture.root / "curated.json").read_text())
                for entry in output["stages"][0]["results"]:
                    self.assertTrue(entry["identityPassed"])
                    self.assertEqual(entry["resolvedBackend"], "paged")
                    self.assertEqual(entry["firstTokenMilliseconds"], 12.5)
                    self.assertNotIn("assistantIdentity", entry)
                    self.assertNotIn("outputText", entry)
                    if scores:
                        self.assertEqual(entry["meanForcedTokenNLL"], 1.25)
                        self.assertTrue(entry["diagnosticChecks"]["finiteLogits"])
                        self.assertNotIn("taskPassed", entry)
                        self.assertNotIn("answer", entry)
                    else:
                        self.assertFalse(entry["taskPassed"])
                        self.assertEqual(entry["answer"], {"answer": "wrong"})
                        self.assertNotIn("meanForcedTokenNLL", entry)

    def test_generation_task_failure_returns_nonzero_and_retains_all_evidence(self):
        for settings in ({"wrongAnswer": True}, {"finishReason": "length"}, {"outputText": "not-json"}):
            with self.subTest(settings=settings), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), settings)
                result, manifest = fixture.run()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(len(manifest["results"]), 2)
                for entry in manifest["results"]:
                    self.assertTrue(entry["reportParsed"])
                    self.assertTrue(entry["identityPassed"])
                    self.assertFalse(entry["taskPassed"])
                self.assertEqual(fixture.curate().returncode, 0)

    def test_curator_rejects_forged_assistant_identity_binding_without_raw_changes(self):
        for mutation in ("identity", "path", "filename"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                fixture.make_assistant()
                result, manifest = fixture.run(mtp=True, assistant=fixture.assistant)
                self.assertEqual(result.returncode, 0, result.stderr)
                binding = manifest["qualification"]["assistant"]
                if mutation == "identity":
                    binding["identities"]["fixture"]["weight_sha256.weights.safetensors"] = "f" * 64
                elif mutation == "path":
                    binding["path"] = str(fixture.assistant)
                else:
                    binding["files"]["../weights.safetensors"] = binding["files"].pop("weights.safetensors")
                (fixture.stage / "run.json").write_text(json.dumps(manifest))
                self.assertNotEqual(fixture.curate().returncode, 0)

    def test_changed_task_or_score_bytes_never_launch_either_arm(self):
        for file in ("prompt", "score"):
            with self.subTest(file=file), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                path = getattr(fixture, file)
                path.write_text(path.read_text() + " ")
                result, _ = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Prepared input changed", result.stderr)
                self.assertFalse(fixture.marker.exists())

    def test_actual_raw_input_date_and_backend_mismatches_fail(self):
        for setting, value, scores in (("promptHash", "f" * 64, False), ("date", "2000-01-01", False),
                                      ("scoreHash", "f" * 64, True), ("backend", "contiguous", False)):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {setting: value})
                result, manifest = fixture.run(scores=scores)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(manifest["results"]), 2)
                self.assertTrue(all(not entry["reportParsed"] for entry in manifest["results"]))
                self.assertTrue(all("parseError" in entry for entry in manifest["results"]))

    def test_drift_during_arm_is_retained_and_stops_next_arm(self):
        for setting in ("mutateInput", "mutateConfig", "mutateSnapshot"):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {setting: True})
                result, manifest = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(manifest["results"]), 1)
                self.assertFalse(manifest["results"][0]["reportParsed"])
                self.assertEqual(fixture.marker.read_text().splitlines(), ["native"])
                self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())
                self.assertFalse(list(fixture.config.parent.glob(".qualification-*.toml")))

    def test_failed_unparsed_children_are_preserved_without_invented_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), {"badJSON": True})
            result, manifest = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual([entry["exitCode"] for entry in manifest["results"]], [2, 2])
            self.assertTrue(all(not entry["reportParsed"] for entry in manifest["results"]))
            self.assertFalse(Path(manifest["qualification"]["activeConfigPath"]).exists())
            self.assertEqual(fixture.curate().returncode, 0)
            before = (fixture.stage / "run.json").read_bytes()
            result, _ = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((fixture.stage / "run.json").read_bytes(), before)

    def test_curator_rejects_forged_environment_and_input_bindings(self):
        for mutation in ("environment", "prompt", "score", "identity", "config"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                scores = mutation == "score"
                result, manifest = fixture.run(scores=scores)
                self.assertEqual(result.returncode, 0, result.stderr)
                if mutation == "environment":
                    env = manifest["qualification"]["environment"]
                    env["values"]["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK"] = "1"
                    env["SHA256"] = hashlib.sha256(json.dumps(env["values"], sort_keys=True, separators=(",", ":")).encode()).hexdigest()
                elif mutation == "identity":
                    manifest["results"][0]["inputIdentity"]["promptSHA256"] = "f" * 64
                elif mutation == "config":
                    snapshot = fixture.stage / "provider-config.toml"
                    snapshot.write_text(snapshot.read_text() + " ")
                else:
                    fixture.mutate_report("scores" if scores else "retrieval", lambda report: report.update(
                        **({"inputSHA256": "f" * 64} if scores else {"promptSHA256": "f" * 64})))
                    manifest = json.loads((fixture.stage / "run.json").read_text())
                (fixture.stage / "run.json").write_text(json.dumps(manifest))
                curated = fixture.curate()
                self.assertNotEqual(curated.returncode, 0)

    def test_legacy_input_validation_is_explicit_without_relabeling_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            result, manifest = fixture.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest["schema"] = 1
            del manifest["qualification"]
            (fixture.stage / "run.json").write_text(json.dumps(manifest))
            self.assertEqual(fixture.curate(inputs=True).returncode, 0)
            output = json.loads((fixture.root / "curated.json").read_text())
            self.assertNotIn("qualification", output["stages"][0])
            fixture.mutate_report("retrieval", lambda report: report.update(promptSHA256="f" * 64))
            self.assertNotEqual(fixture.curate(inputs=True).returncode, 0)

    def test_unknown_or_malformed_run_schema_cannot_bypass_bindings(self):
        for schema in (3, 99, True, False, "2", None):
            with self.subTest(schema=schema), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                result, manifest = fixture.run()
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest["schema"] = schema
                del manifest["qualification"]
                (fixture.stage / "run.json").write_text(json.dumps(manifest))
                curated = fixture.curate()
                self.assertNotEqual(curated.returncode, 0)
                self.assertIn("Unsupported qualification run schema", curated.stderr)


if __name__ == "__main__":
    unittest.main()
