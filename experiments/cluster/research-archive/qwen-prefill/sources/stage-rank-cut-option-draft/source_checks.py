"""CPU-only packaging and guard-order checks; does not compile or run Swift."""
import argparse
import copy
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REL = "experiments/cluster/inference/Sources/ClusterInference/"
BINDING = "    try QwenLayerStageComparisonAdmission.validatePlanBinding(options, inputs: inputs)\n"
FOREIGN = ("QwenLayerStageLookaheadAdmission.swift", "QwenLayerStagePrefillRankAdmission.swift")


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def guard_contract(proposed):
    options = proposed["Options.swift"]
    scope = options.split("// Check the original CLI mode before any admission adapter rewrites it.", 1)[1]
    scope = scope.split("        guard mode == .capability", 1)[0]
    require("guard (mode == .qwenLayerStageCompare || mode == .qwenLayerStageRankCheck)," in scope,
            "Original CLI mode is not the closed compare/rank set")
    require("(1...127).contains(cut)" in scope and scope.count("mode ==") == 2,
            "Cut literal cap or original mode set changed")
    require(options.index(scope) < options.index("else if mode == .qwenLayerStageRankCheck"),
            "Original cut gate follows admission dispatch")
    runner = proposed["QwenLayerStageRankCheck.swift"]
    require(runner.count(BINDING) == 1, "Runner requires exactly one selected-plan binding")
    require(runner.index("try QwenLayerStageRankAdmission.validateOptions(options)") < runner.index(BINDING)
            < runner.index("let collective = try Collective("), "Selected-plan binding must precede Collective")
    for name in FOREIGN:
        source = proposed[name]
        require(source.index("guard options.stageCut == nil") < source.index("try QwenLayerStageRankAdmission.validateOptions"),
                name + " can leak a foreign cut through its rank clone")
    for name in ("QwenLayerStagePrefillAdmission.swift", "QwenLayerStageSoloPrefillCLIAdmission.swift"):
        source = proposed[name]
        require(source.index("guard options.stageCut == nil") < source.index("try QwenLayerStageComparisonAdmission.validateOptions"),
                name + " can leak a foreign cut through its comparison clone")


def validate(repository):
    checked = []
    inventory = json.loads((ROOT / "base-inventory.json").read_text())
    originals = {name: (ROOT / "originals" / name).read_text() for name in inventory}
    proposed = {p.name: p.read_text() for p in (ROOT / "proposed").glob("*.swift")}
    require(set(proposed) == set(inventory) | {"QwenLayerStageRankCutAdmissionCheck.swift"}, "Unexpected source delta")
    for name, pin in inventory.items():
        require(digest((ROOT / "originals" / name).read_bytes()) == pin, "Original snapshot drift: " + name)
        require(digest((repository / REL / name).read_bytes()) == pin, "Repository base drift: " + name)
    checked.append("eight replacement bases match captured repository bytes")
    patch = "".join("".join(difflib.unified_diff(originals[name].splitlines(True), proposed[name].splitlines(True),
        fromfile="a/" + REL + name, tofile="b/" + REL + name)) for name in inventory)
    require(patch == (ROOT / "runtime.patch").read_text(), "Patch does not exactly reconstruct replacements")
    checked.append("patch exactly reconstructs all replacement files")
    require(proposed["QwenLayerStageRankCheck.swift"].replace(BINDING, "") == originals["QwenLayerStageRankCheck.swift"],
            "Rank runner has a delta beyond pre-Collective plan binding")
    checked.append("rank runner math, ownership, report and cleanup remain byte-identical")
    guard_contract(proposed)
    checked.append("closed original CLI gate and foreign clone rejection precede dependent work")
    for name, pin in json.loads((ROOT / "unchanged-dependencies.json").read_text()).items():
        require(name not in inventory and name not in proposed, "Changed dependency listed as unchanged")
        require(digest((repository / REL / name).read_bytes()) == pin, "Unchanged dependency drift: " + name)
    checked.append("pinned planner, budget, request, fixture, loader, session and wire dependencies unchanged")
    fixture = proposed["QwenLayerStageRankCutAdmissionCheck.swift"]
    require(fixture.startswith("import Foundation\n") and "Collective(" not in fixture and "MLXArray(" not in fixture,
            "Pure fixture acquired native execution")
    require("[Int.min, -1, 0, Int.max]" in fixture and "selected cut with stale half plan" in fixture
            and "selected half with stale unequal plan" in fixture, "Required malformed/stale-input fixture omitted")
    checked.append("new fixture stays CPU metadata-only and includes malformed/stale input coverage")
    mutations = []

    def rejected(label, change):
        mutant = copy.copy(proposed)
        change(mutant)
        try:
            guard_contract(mutant)
        except (ValueError, IndexError):
            mutations.append(label)
            return
        raise ValueError("Source check accepted mutation: " + label)

    rejected("foreign original mode", lambda p: p.__setitem__("Options.swift", p["Options.swift"].replace(
        "mode == .qwenLayerStageCompare || mode == .qwenLayerStageRankCheck)",
        "mode == .qwenLayerStageCompare || mode == .qwenLayerStageLookaheadCheck)")))
    rejected("weakened cut literal cap", lambda p: p.__setitem__("Options.swift", p["Options.swift"].replace(
        "(1...127).contains(cut)", "(1...128).contains(cut)")))
    rejected("missing selected-plan binding", lambda p: p.__setitem__("QwenLayerStageRankCheck.swift",
        p["QwenLayerStageRankCheck.swift"].replace(BINDING, "")))
    rejected("late selected-plan binding", lambda p: p.__setitem__("QwenLayerStageRankCheck.swift",
        p["QwenLayerStageRankCheck.swift"].replace(BINDING, "").replace(
            "    let collective = try Collective(transport: options.transport)\n",
            "    let collective = try Collective(transport: options.transport)\n" + BINDING)))
    for name in FOREIGN:
        rejected("missing foreign cut guard: " + name, lambda p, n=name: p.__setitem__(n,
            p[n].replace("guard options.stageCut == nil", "guard true")))
    return {"kind": "short_rank_cut_source_checks", "source_only": True, "passed": True,
            "checks": checked, "check_count": len(checked), "rejected_source_mutations": mutations,
            "rejected_source_mutation_count": len(mutations), "swift_compiled": False,
            "swift_fixtures_executed": False, "native_model_collective_or_network_executed": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    arguments = parser.parse_args()
    print(json.dumps(validate(arguments.repository), indent=2, sort_keys=True))
