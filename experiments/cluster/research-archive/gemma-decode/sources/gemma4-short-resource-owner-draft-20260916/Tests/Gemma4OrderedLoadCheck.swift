import Foundation

func checkOrderedLoad(_ input: FixtureInputs, _ checks: FixtureChecks) throws {
    let plan = try Gemma4LayerStagePlan(artifact: input.artifact, cut: 10)
    for (name, target) in [("full", Gemma4ForwardTarget.fullReference), ("rank0", .stage(0)), ("rank1", .stage(1))] {
        let selected = try Gemma4ForwardSelection.make(plan: plan, target: target)
        var progress = Gemma4OrderedLoadProgress(expected: selected)
        var remaining = selected.reduce(0) { $0 + $1.source.layout.byteCount }
        for (index, tensor) in selected.enumerated() {
            try progress.begin(tensor)
            guard progress.completed == index, progress.pending == index,
                  selected.dropFirst(progress.completed).reduce(0, { $0 + $1.source.layout.byteCount }) == remaining else {
                throw ProbeError("Pending read retired its reserve before completion")
            }
            try progress.finish(tensor)
            remaining -= tensor.source.layout.byteCount
            guard progress.completed == index + 1, progress.pending == nil else { throw ProbeError("Completion did not advance exactly once") }
        }
        try progress.requireFinished()
        try checks.require(name + " ordered actual descriptor completion", remaining == 0 && !progress.failed)
        try checks.refuses(name + " refuses read after completion") { try progress.begin(selected[0]) }
        try checks.require(name + " completion overrun poisons owner", progress.failed)
    }
    let selected = try Gemma4ForwardSelection.make(plan: plan, target: .stage(0))
    for scenario in 0..<7 {
        var progress = Gemma4OrderedLoadProgress(expected: selected)
        try checks.refuses("ordered load refusal\(scenario)") {
            switch scenario {
            case 0: try progress.finish(selected[0])
            case 1: try progress.begin(selected[0]); try progress.begin(selected[0])
            case 2: try progress.begin(selected[1])
            case 3: try progress.begin(selected[0]); try progress.finish(selected[1])
            case 4:
                try progress.begin(.init(source: selected[0].source, localName: "substituted"))
            case 5: try progress.begin(selected[0]); try progress.requireFinished()
            default: try progress.requireFinished()
            }
        }
        try checks.require("ordered refusal\(scenario) is sticky", progress.failed)
        try checks.refuses("ordered refusal\(scenario) cannot resume") { try progress.begin(selected[0]) }
    }
    var poisoned = Gemma4OrderedLoadProgress(expected: selected)
    poisoned.poison()
    try checks.refuses("explicit failure cannot resume load") { try poisoned.begin(selected[0]) }
}
