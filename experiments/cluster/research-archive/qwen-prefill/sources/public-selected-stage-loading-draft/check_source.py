#!/usr/bin/env python3
"""Read-only source/packaging checks; never invokes the Swift runner."""
from pathlib import Path
import hashlib
import json
import posixpath
import re

DRAFT = Path(__file__).resolve().parent
REPOSITORY = DRAFT.parent.parent / "d-inference"
NATIVE = "experiments/cluster/inference"
TESTS = NATIVE + "/Tests/SelectedStageLoading"

def digest(data):
    return hashlib.sha256(data).hexdigest()

def pinned(path, expected, size=None):
    path = Path(path)
    assert path.is_file() and not path.is_symlink(), str(path)
    data = path.read_bytes()
    assert digest(data) == expected, str(path)
    assert size is None or len(data) == size, str(path)
    return data

def verify():
    mapping = json.loads((DRAFT / "source-map.json").read_bytes())
    for key in ["runtime_freeze", "fixture_v2_source_list"]:
        pinned(mapping[key]["path"], mapping[key]["sha256"])
    sources = mapping["sources"]
    assert len(sources) == 30 and len({x["public_path"] for x in sources}) == 30
    for item in sources:
        pinned(item["source_path"], item["sha256"], item["size_bytes"])
    stdin = mapping["stdin"]
    pinned(stdin["path"], stdin["sha256"], stdin["bytes"])
    for item in mapping["documentation_bases"]:
        pinned(REPOSITORY / item["path"], item["sha256"])
    runner_path = DRAFT / "proposed" / TESTS / "run.sh"
    runner = runner_path.read_text()
    extracted = re.findall(r'  "\$(source_dir|test_dir)/([^"\n]+\.swift)"', runner)
    resolved = [posixpath.normpath((NATIVE + "/Sources/ClusterInference" if scope == "source_dir" else TESTS) + "/" + tail) for scope, tail in extracted]
    assert resolved == [x["public_path"] for x in sources]
    assert "-parse-as-library -swift-version 6 -warnings-as-errors" in runner
    assert '\"$test_dir/../RegisteredDenseProfiles/retained-inputs.json\"' in runner
    assert "trap 'rm -rf -- \"$check_dir\"' EXIT" in runner
    doc_path = DRAFT / "proposed" / NATIVE / "QWEN_DENSE_STAGE_LOADING.md"
    doc = doc_path.read_text()
    assert doc.splitlines()[2] == "> Last updated: 2026-09-14 · commit `e4df336bc`"
    assert "/Users/" not in doc and "/Users/" not in runner
    known = set(x["public_path"] for x in sources)
    known.update(NATIVE + "/Sources/ClusterInference/" + p.name for p in (DRAFT.parent / "registered-dense-stage-load-draft").glob("*.swift"))
    link_count = 0
    for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', doc):
        assert not target.startswith(("http:", "https:", "file:"))
        path = posixpath.normpath(NATIVE + "/" + target.split("#", 1)[0])
        assert (REPOSITORY / path).is_file() or path in known, target
        link_count += 1
    return {"schema_version": 1, "kind": "public_selected_stage_loading_source_checks", "passed": True,
        "source_inputs_verified": 30, "retained_metadata_inputs": 1, "source_links_verified": link_count,
        "runner_source_order_matches_v2_list": True, "fixture_or_metadata_copied": False,
        "swift_runner_compiler_native_or_ssh_executed": False, "candidate_payload_accessed": False,
        "runner_sha256": digest(runner_path.read_bytes()), "documentation_sha256": digest(doc_path.read_bytes()),
        "docs_patch_sha256": digest((DRAFT / "docs.patch").read_bytes()),
        "source_map_sha256": digest((DRAFT / "source-map.json").read_bytes())}

if __name__ == "__main__":
    print(json.dumps(verify(), indent=2, sort_keys=True))
