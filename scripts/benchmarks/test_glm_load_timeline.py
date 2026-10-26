import datetime as dt
import unittest

import glm_load_timeline

# M5 Ultra, standalone GLM-5.3-Flash on the v0.10.0 load path, 2026-10-22
# (process started 20:10:31 local): two bracketing weight-hash passes around
# the native load, then the shape warmup.
BEFORE = """\
2026-10-22T20:10:37-0700 info darkbloom.WeightHasher: [ProviderCoreFoundation] Computing weight hash for EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp (42 files)...
2026-10-22T20:11:02-0700 info darkbloom.WeightHasher: [ProviderCoreFoundation] Weight hash for EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp: 3aae613ff188bb0f
2026-10-22T20:12:06-0700 info darkbloom.WeightHasher: [ProviderCoreFoundation] Computing weight hash for EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp (42 files)...
2026-10-22T20:12:31-0700 info darkbloom.WeightHasher: [ProviderCoreFoundation] Weight hash for EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp: 3aae613ff188bb0f
2026-10-22T20:12:52-0700 info darkbloom.ShapeWarmup: [ProviderCore] Shape warmup EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp: budget 1/2 cells in 20021 ms (attempt 1, width 4, probe 5907/230 ms)
2026-10-22T20:12:52-0700 info darkbloom-provider: [HummingbirdCore] Server started and listening on 127.0.0.1:8101
"""

AFTER = """\
2026-10-22T21:00:20-0700 info darkbloom.WeightHasher: [ProviderCoreFoundation] Weight hash for glm-5.3-flash: 3aae613ff188bb0f (recorded by its last full verification; file identities unchanged, the load verifies again before serving)
2026-10-22T21:01:30-0700 info darkbloom.GLM5NextLoad: [ProviderCore] GLM load glm-5.3-flash: all 42 manifest files SHA-256 verified before serving; auxiliary verification 0.1 s, core verification 25.2 s, tensors and construction 38.9 s, total 64.4 s
2026-10-22T21:01:52-0700 info darkbloom-provider: [HummingbirdCore] Server started and listening on 127.0.0.1:8101
"""


class TimelineTest(unittest.TestCase):
    def test_v0_10_standalone_start_reads_the_weights_in_two_hash_passes(self):
        started = dt.datetime(2026, 10, 23, 3, 10, 31, tzinfo=dt.timezone.utc)
        result = glm_load_timeline.timeline(BEFORE.splitlines(), started)
        self.assertEqual(result["weight_hash_passes"], 2)
        self.assertEqual(result["ready_seconds"], 141.0)
        passes = [p for p in result["phases"] if p["phase"].startswith("weight hash pass")]
        self.assertEqual([p["seconds"] for p in passes], [25.0, 25.0])
        self.assertEqual([p["offset_seconds"] for p in passes], [6.0, 95.0])
        warmup = next(p for p in result["phases"] if p["phase"] == "shape warmup")
        self.assertAlmostEqual(warmup["seconds"], 20.021)

    def test_verified_load_reports_its_phases_and_no_hash_pass(self):
        result = glm_load_timeline.timeline(AFTER.splitlines())
        self.assertEqual(result["weight_hash_passes"], 0)
        self.assertEqual(result["weight_hash_reused"], 1)
        self.assertEqual(result["glm_verified_loads"], 1)
        names = [p["phase"] for p in result["phases"]]
        self.assertIn("GLM core SHA-256 verification", names)
        self.assertEqual(result["ready_seconds"], 92.0)


if __name__ == "__main__":
    unittest.main()
