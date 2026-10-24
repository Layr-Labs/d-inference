"""Cheap preservation and resource-wiring checks; no Swift build or GPU required."""

import hashlib
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).resolve().parent / "ProviderCoreTests"
FIXTURES = TESTS / "Fixtures/Protocol"
# Digests captured from the original shared fixtures before platform removal.
SHA256 = {
    "calibrated_capacity_wire_fixture": "c73d1be2972540dbe48e8cc5b3871a15f44dcbafb4f8c51f6ee27e88b01c2e41",
    "calibrated_deadline_decisions": "079a387c50070d2742e95dee1c6a8115ba49d10934eacc219574adb8c4ac6650",
    "deadline_coverage_confidence": "3a96307ff7cdb2e3949c039313549d1f2e0142b8f49fc2d23b20882704d760eb",
    "deadline_unbounded_reasons": "547b9cdf473f19d120e9f2e5db5dd47d3211796f8b1b85d685c7dce748aa1d4c",
    "paged_footprint_wire": "3b3a1777e129972a504eb2267f865a410d64839bc014828eea00fd4b04742483",
    "performance_capacity_wire_fixture": "e55e3ec2791480985d3cf099e94d0439f594e426d41d22444daa9ceb4de4aa77",
    "process_memory_wire": "7eb6c13f7028535900e6b4ad7dae71268d9cc4dd65374508b5444ce4c58ff84e",
    "profiler_wire_fixture": "244bae582cafbf15d284a33c81449184ca70dc8e13806f5665402043e355c893",
}
LOADERS = {
    "Protocol/ServingPerformanceProfileWireTests.swift": [
        "performance_capacity_wire_fixture", "calibrated_capacity_wire_fixture"],
    "Protocol/DeadlineDecisionProfileTests.swift": ["deadline_unbounded_reasons"],
    "Protocol/PagedFootprintTelemetryTests.swift": ["paged_footprint_wire"],
    "Protocol/ProtocolTests.swift": ["profiler_wire_fixture"],
    "Inference/Performance/Deadline/DeadlineCoverageConfidenceTests.swift": ["deadline_coverage_confidence"],
    "Inference/Performance/Deadline/DeadlineDecisionFixtureTests.swift": ["calibrated_deadline_decisions"],
    "Inference/Memory/ProcessMemoryTelemetryTests.swift": ["process_memory_wire"],
}


class ProtocolFixtureResourcesTests(unittest.TestCase):
    def test_original_fixture_bytes_are_preserved(self):
        self.assertEqual({path.stem for path in FIXTURES.glob("*.json")}, set(SHA256))
        for name, digest in SHA256.items():
            with self.subTest(fixture=name):
                data = (FIXTURES / (name + ".json")).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                json.loads(data)

    def test_loaders_require_the_copied_bundle_resources(self):
        manifest = (ROOT / "provider-swift/Package.swift").read_text()
        target = manifest.split('name: "ProviderCoreTests",', 1)[1].split('\n        ),', 1)[0]
        self.assertIn('resources: [.copy("Fixtures")]', target)
        for path, names in LOADERS.items():
            with self.subTest(loader=path):
                source = (TESTS / path).read_text()
                resources = re.findall(
                    r'try #require\(Bundle\.module\.url\(\s*forResource: "([^"]+)", '
                    r'withExtension: "json", subdirectory: "Fixtures/Protocol"\)\)', source)
                self.assertCountEqual(resources, names)
                self.assertNotIn("#filePath", source)
                self.assertNotRegex(source, r'"(?:coordinator/|go\.mod)')

    def test_prompt_fixture_root_uses_only_retained_markers(self):
        source = (TESTS / "Inference/Prompting/CachePromptParityTests.swift").read_text()
        markers = re.findall(r'fileExists\(atPath: root\.appendingPathComponent\("([^"]+)"\)\.path\)', source)
        self.assertEqual(markers, ["provider-swift/Package.swift", "fixtures/prompt-contract/v1"])
        for marker in markers:
            self.assertTrue((ROOT / marker).exists(), marker)
        self.assertNotRegex(source, r'"(?:coordinator/|go\.mod)')


if __name__ == "__main__":
    unittest.main()
