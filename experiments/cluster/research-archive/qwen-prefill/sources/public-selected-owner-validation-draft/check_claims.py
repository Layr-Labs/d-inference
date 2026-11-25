"""Check this prose against saved audit receipts; do not rerun any oracle/native work."""
from pathlib import Path
from decimal import Decimal
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
REPO = RESEARCH.parent / "d-inference/experiments/cluster/inference"
SOLO = "runs/qwen-long-prefill-solo-owner-r2-peer24-20260914/"
RANK = "runs/qwen-long-prefill-ranks-serial-owner-peer24-20260914/"
SOLO_TRACES = "runs/qwen-long-prefill-solo-owner-r2-sidecars-v2-20260914/"
RANK_TRACES = "runs/qwen-long-prefill-ranks-serial-owner-sidecars-20260914/"
PINS = {
    SOLO + "receipt.json": "a9a26682d86a98bfde82981e34c725e822e15c693cc4dbe02542bd1324127048",
    RANK + "receipt.json": "fc012d9ca03d3bdb5e56468805fdd60c52c18638dd119c728281518542e82ba7",
    SOLO + "independent-cpu-audit.json": "af6d7412a6b63423bf8a7178d25e9589d55823faf532ae15124441a8e87f8cc1",
    RANK + "independent-cpu-audit.json": "c58181be4266493ea8af9fec8c887665e79ceda64a04fc0049ca3e735212ce4a",
    SOLO + "owner-source-correlation.json": "70f2a04761c6df1ef36ef2f03e66eda933f14b8abe0ec807db3fcf9d3de94e4c",
    RANK + "owner-source-correlation.json": "f2ce5f9b937f6d3e92712b6eca76b96fe3d80cf93af05fc89f01b5c91ec92b0d",
    SOLO_TRACES + "owner-audit.json": "21805c081b5b55809756c34d4e57741e8bad60681e8f2c57e7453b2c7cfad96c",
    RANK_TRACES + "owner-audit.json": "6add1882259a655b408f16884cdad26da419aee3783caff3a2d3c62a9d47772d",
    SOLO_TRACES + "owner-audit-receipt.json": "9cee5ae917d740daeddbd26e8255634089fab2b04023f72cfb925ce9c49a15f5",
    RANK_TRACES + "owner-audit-receipt.json": "6007828bd4cbfed6869adef9c2f870c922d9802720fb6230b0891fd539ecb7bc",
    SOLO_TRACES + "receipt.json": "e101221a4d46f1c2b2093edbe176798b8b940640dd4896c8af2ca258845f6845",
    RANK_TRACES + "receipt.json": "1cd8c5d028c589498b5d0809cb1815392641d6d2d36d7c097d72c4d6c227ea33",
    "runs/qwen-long-prefill-solo-owner-peer24-20260914/receipt.json": "1f7d5219ef67cbb61274979ab73f867a45fc824dd56c589cddf91db300402858",
    "runs/qwen-long-prefill-solo-owner-r2-sidecars-20260914/receipt.json": "32024df914f02cb3f47a1aa1d9796407a77618178496a6fdc1f3236abddc588a",
    "owner-operator-audit-draft/manifest.json": "01564e53ceb50ac482245f13f2b068c90b90ec8977815638e701fe82cd5e30e8",
    "qwen-prefill-owner-build-checkpoint-20260914.json": "a359c1cccc1377542fd4e837c33cb0aac832d224581d7078564240354bbd5dae",
}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path):
    with path.open("rb") as stream:
        raw = stream.read(8 * 1024 * 1024 + 1)
    assert 0 < len(raw) <= 8 * 1024 * 1024
    return raw


def check():
    raw = {name: read(RESEARCH / name) for name in PINS}
    assert all(sha(raw[name]) == digest for name, digest in PINS.items())
    value = {name: json.loads(data) for name, data in raw.items()}
    document = read(HERE / "QWEN_PREFILL_OWNER_VALIDATION.md")
    text = document.decode()
    assert text.splitlines()[2] == "> Last updated: 2026-09-14 · commit `e4df336bc`"
    assert len(text.splitlines()) <= 90
    assert not re.search(r"/Users/developer/", text, re.I)
    links = re.findall(r"\]\(([^)]+)\)", text)
    assert links and all(not x.startswith(("/", "http", "file:")) and (REPO / x).is_file() for x in links)

    owner = [value[SOLO_TRACES + "owner-audit.json"], *value[RANK_TRACES + "owner-audit.json"]["ranks"]]
    counts = [41, 204, 235]
    observed = []
    for index, row in enumerate(owner):
        assert row["status"] == "passed" and row["ownerEventCount"] == 8
        assert row["coarsePhaseEventCount"] == counts[index]
        assert {k: row["identity"][k] for k in ("frameSequence", "tokenOffset", "tokenCount", "committedFrontier")} == {
            "frameSequence": 7, "tokenOffset": 3584, "tokenCount": 512, "committedFrontier": 4096}
        assert row["allOwnerEventsContainedInSameRoleSelectedParent"] is True
        spans = [entry["elapsedNanoseconds"] for entry in row["intervals"]]
        rendered = [f"{n // 1000000}.{n % 1000000:06d}" for n in spans]
        assert all(number in text for number in rendered)
        observed.append(dict(role=row["role"], intervalsNanoseconds=spans))

    timings = []
    for prefix in (SOLO, RANK):
        launch = value[prefix + "receipt.json"]
        assert launch["passed"] and launch["primary_failure"] is None
        assert launch["cleanup_errors"] == launch["post_run_errors"] == []
        assert launch["expected_native_sha256"] == "963a1db39865266a1a0f5c20b9404435a4243d131957dbbbd1e157fe7ca1c0c5"
        assert launch["source_manifest_sha256"] == "ffa4eb9d79629dc2323e4fcf22cc01f840fe8a868913e14cd9242a39a135e499"
        samples = launch["remote_memory_samples"]
        assert len(samples) == 23 and all(s["pressure_level"] == 1 and Decimal(s["swap_used_bytes"]) == 0 for s in samples)
        assert samples[-1]["remote_pid_inventory"]["observed_processes"] == []
        correlation = value[prefix + "owner-source-correlation.json"]
        assert correlation["passed"] and len(correlation["matchedOwnerSourceFiles"]) == 22
        assert correlation["verifiedArchivedSourceFiles"] == 327
        audit = value[prefix + "independent-cpu-audit.json"]
        assert audit["status"] == "passed" and audit["selectedTokenID"] == 271
        assert audit["candidateStateMetadataAndDigestsExact"] and audit["candidateLogitMetadataAndDigestExact"]
        assert not audit["candidateNativeBytesIndependentlyReconstructed"]
        assert audit["finalStateLogicalBytes"] == 319946784 and audit["opaqueNumericalStateComponents"] == 64
        assert audit["baselineFinalLogits"]["byteCount"] == 496640
        timing = audit["timing"]["elapsedNanoseconds"]
        assert f"{timing // 1000000000}.{timing % 1000000000:09d} s" in text
        timings.append(timing)

    for prefix, expected_count in ((SOLO_TRACES, 2), (RANK_TRACES, 4)):
        audit_receipt = value[prefix + "owner-audit-receipt.json"]
        retrieval = value[prefix + "receipt.json"]
        assert audit_receipt["passed"] and audit_receipt["auditExitCode"] == 0
        assert retrieval["passed"] and len(retrieval["sidecars"]) == expected_count
        for entry in retrieval["sidecars"]:
            assert entry["passed"] and entry["ssh"]["local_reader_ssh_client_reaped"]
            data = read(RESEARCH / prefix / entry["sidecar"]["path"])
            assert sha(data) == entry["sidecar"]["sha256"]
            if entry["name"] == "owner":
                assert len(data) == 1770
        assert audit_receipt["auditorFrozenBeforeNativeInvocation"] is (prefix == RANK_TRACES)
    failed = value["runs/qwen-long-prefill-solo-owner-peer24-20260914/receipt.json"]
    assert not failed["passed"] and failed["execution"]["exit_code"] == 0
    assert "Source drift:" in failed["primary_failure"]["error"]
    failed_reader = value["runs/qwen-long-prefill-solo-owner-r2-sidecars-20260914/receipt.json"]
    assert not failed_reader["passed"] and failed_reader["sidecars"] == []
    assert "Bundle is outside the owned run" in failed_reader["primary_failure"]["error"]
    build = value["qwen-prefill-owner-build-checkpoint-20260914.json"]
    assert build["passed"] and build["buildSeconds"] == 70.27 and build["adapterRecords"] == 35
    assert (build["ownerAcceptedTraces"], build["ownerRejectedCalls"], build["ownerOutputCases"]) == (6, 90, 11)
    assert value["owner-operator-audit-draft/manifest.json"]["testsPassed"] == 67
    assert all(read(RESEARCH / name) == content for name, content in raw.items())
    return dict(passed=True, scope="document values, saved receipt pins and relative source links only",
        documentSHA256=sha(document), lineCount=len(text.splitlines()), wordCount=len(text.split()),
        relativeLinks=len(links), selectedIntervals=observed, fullRequestNanoseconds=timings,
        evidencePins=PINS, reranNumericalOrTimingOracle=False, nativeOrSSHExecuted=False,
        independentlyRebuiltBinary=False, independentlyReplayedFullProvenance=False)


if __name__ == "__main__":
    print(json.dumps(check(), indent=2, sort_keys=True))
