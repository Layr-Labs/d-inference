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

ROOT = Path(__file__).parent
RUNNER = ROOT / "run_suite.py"
CURATOR = ROOT / "curate_runs.py"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


CHILD = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys
args=sys.argv[1:]
def option(name):return args[args.index(name)+1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
config=pathlib.Path(option('--config'))
settings=json.loads(config.read_text())
if settings.get('relativeCache'):
    assert (config.parent/settings['relativeCache']).is_dir()
with pathlib.Path(settings['marker']).open('a') as f:f.write(option('--kv-quantization')+'\n')
if settings.get('badJSON'):
    print('failed before a report');sys.exit(2)
score='--teacher-forced-input' in args
path=pathlib.Path(option('--teacher-forced-input' if score else '--runtime-prompt-file'))
document=json.loads(path.read_text()) if score else json.loads((path.parent/'fixture-scores-input.json').read_text())
report={'verifiedModelAggregateSHA256':document['expectedModelAggregateSHA256'],
        'resolvedBackend':settings.get('backend','paged'),'kvQuantization':option('--kv-quantization'),
        'observedEnvironment':dict(os.environ),'configPath':str(config.resolve())}
binary=sha(pathlib.Path(sys.argv[0]));metal=sha(pathlib.Path(sys.argv[0]).parent/'mlx.metallib')
if score:
    diagnostic={'records':[{'nanCount':0,'infiniteCount':0}],'top1':[3]}
    report.update(executableSHA256=binary,metallibSHA256=metal,input=document,
                  inputSHA256=settings.get('scoreHash',sha(path)),diagnostic=diagnostic,
                  repeatedDiagnostic=diagnostic,plainTop1=[3],meanForcedTokenNLL=1.25)
else:
    answer={'answer':'contaminated' if 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK' in os.environ else 'ok'}
    report.update(runtimeIdentity={'binary_sha256':binary,'metallib_sha256':metal},
                  promptSHA256=settings.get('promptHash',sha(path)),
                  renderDate=settings.get('date',option('--runtime-prompt-date')),
                  finishReason='stop',text=json.dumps(answer))
if settings.get('mutateInput'):path.write_text(path.read_text()+' ')
if settings.get('mutateConfig'):config.write_text(config.read_text()+' ')
print(json.dumps(report))
'''


class Fixture:
    def __init__(self, root, settings=None):
        self.root = root
        self.candidate = root / "candidate"
        self.inputs = root / "prepared"
        self.stage = root / "stage"
        self.config = root / "config" / "provider.toml"
        self.marker = root / "child-called"
        self.candidate.mkdir()
        self.inputs.mkdir()
        self.config.parent.mkdir()
        (root / "relative-models").mkdir()
        self.config.write_text(json.dumps(dict(marker=str(self.marker), relativeCache="../relative-models", **(settings or {}))))
        binary = self.candidate / "darkbloom"
        binary.write_text(CHILD)
        binary.chmod(0o755)
        metal = self.candidate / "mlx.metallib"
        metal.write_text("CPU fixture only; not a GPU artifact\n")
        self.artifacts = {"darkbloom": digest(binary), "mlx.metallib": digest(metal)}
        (self.candidate / "source-receipt.json").write_text(json.dumps({
            "source_file_digest": "fixture-source", "artifacts": self.artifacts}))
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

    def run(self, scores=False, environment=None):
        command = [sys.executable, str(RUNNER), "--candidate", str(self.candidate),
                   "--config", str(self.config), "--inputs", str(self.inputs), "--output", str(self.stage),
                   "--models", "fixture", "--tasks", "none" if scores else "retrieval", "--timeout", "10"]
        if scores:
            command.append("--scores")
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=15)
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


class QualificationRunnerContractTests(unittest.TestCase):
    def test_actual_children_are_scrubbed_and_input_config_receipts_curate(self):
        for scores in (False, True):
            with self.subTest(scores=scores), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
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
                for entry in manifest["results"]:
                    self.assertTrue(entry["identityPassed"])
                    self.assertEqual(entry["configBeforeSHA256"], digest(fixture.config))
                    self.assertEqual(entry["configAfterSHA256"], digest(fixture.config))
                    mode = "scores" if scores else "retrieval"
                    report = json.loads((fixture.stage / ("fixture-" + mode + "-" + entry["requestedPrecision"] + ".json")).read_text())
                    self.assertEqual(report["configPath"], str(fixture.config.resolve()))
                    self.assertEqual(report["observedEnvironment"]["TZ"], "UTC")
                    for key in ("DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "DARKBLOOM_CBV2_KV_QUANTIZATION", "MLX_TEST_OVERRIDE", "HF_TOKEN"):
                        self.assertNotIn(key, report["observedEnvironment"])
                curated = fixture.curate()
                self.assertEqual(curated.returncode, 0, curated.stderr)

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
        for setting in ("mutateInput", "mutateConfig"):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary), {setting: True})
                result, manifest = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(manifest["results"]), 1)
                self.assertFalse(manifest["results"][0]["reportParsed"])
                self.assertEqual(fixture.marker.read_text().splitlines(), ["native"])

    def test_failed_unparsed_children_are_preserved_without_invented_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary), {"badJSON": True})
            result, manifest = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual([entry["exitCode"] for entry in manifest["results"]], [2, 2])
            self.assertTrue(all(not entry["reportParsed"] for entry in manifest["results"]))
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
