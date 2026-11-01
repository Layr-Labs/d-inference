"""Choose one independent depth reviewer for each source batch."""
import re

from .context import OPUS, SOL

RISK = re.compile(r"auth|attest|encrypt|crypt|billing|payment|ledger|mdm|enroll|secret|token|permission|\.github/", re.I)
CRITICAL = re.compile(r"attest|encrypt|crypt|\.github/workflows/", re.I)
TEST_NAME = re.compile(r"(?:^|[._-])(?:test|tests|spec)(?:[._-]|$)")


def path_depth(path):
    path = path.lower()
    # Workflows execute even when their names describe tests or documentation.
    if path.startswith(".github/workflows/"):
        return SOL
    parts = path.split("/")
    name = parts[-1]
    support = (parts[0] in ("docs", "changelog.d")
               or any(part in ("test", "tests", "__tests__", "testdata") for part in parts[:-1])
               or name.endswith((".md", ".mdx", ".rst")))
    if support:
        return None
    if CRITICAL.search(path):
        return SOL
    # Swift production names such as AppAttest.swift also end in "test.swift".
    # Only explicit test trees or delimited test/spec names are support hints;
    # a filename hint cannot downgrade critical source outside those trees.
    if TEST_NAME.search(name):
        return None
    return OPUS if RISK.search(path) else None


def source_depth(batch, result):
    """Support files still escalate on findings or uncertainty from the full pass."""
    path_depths = {path_depth(path) for unit in batch
                   for path in (unit["metadata"]["file"], unit["metadata"].get("previous_filename")) if path}
    if SOL in path_depths or any(f["severity"] == "high" for f in result["findings"]):
        return SOL
    if OPUS in path_depths or result["needs_deeper_review"] or result["findings"]:
        return OPUS
    return None
