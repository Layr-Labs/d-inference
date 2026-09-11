"""Existing launch/report contract constants shared by the runner modules."""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPO_ROOT / "provider-swift"
DEFAULT_TARGET_ID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
DEFAULT_ASSISTANT_ID = "mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit"
DEFAULT_TEST_FILTER = "GemmaMTPPerformanceLiveTests"
REPORT_SCHEMA_VERSION = 5
REPORT_NAME = "report.json"
LOG_NAME = "benchmark.log"
SUPERVISOR_CONTRACT = "run-mtp-benchmark-v1"
LEGACY_M5_INACTIVE_REASON_PREFIX = (
    "rectangular MTP verification is disabled on Apple M5"
)
MAX_CACHE_ROOTS = 8
MAX_FALLBACK_REPOSITORY_ENTRIES = 4096
MAX_FALLBACK_REPOSITORIES = 8
MAX_SNAPSHOT_ENTRIES = 512
MAX_REF_BYTES = 256
MAX_REPORT_BYTES = 100 * 1024 * 1024
PERFORMANCE_KEYS = {
    "elapsedMs",
    "medianAggregateDecodeTokensPerSecond",
    "timeToFirstTokenMs",
    "interTokenLatencyMs",
    "decodeTokensPerSecond",
    "lastTokenLatencyMs",
    "ewmaRoundWallTimeNanos",
    "totalRoundWallTimeNanos",
    "assistantTimeNanos",
    "targetVerifyTimeNanos",
}
HEX_DIGITS = frozenset("0123456789abcdef")

