import Foundation
// Only job fields consumed by the byte-exact description selection expression.
// This is a pure source contract check, not a model or resource admission.
struct SelectionJob { let outputCount: Int; let target: Gemma4ForwardTarget }
func selected(_ job: SelectionJob) -> [Gemma4ForwardTarget] {
        let describedTargets: [Gemma4ForwardTarget] = job.outputCount == 16
            ? [.fullReference, .stage(0), .stage(1)] : [job.target]
        return describedTargets
}
struct Failure: Error { let message: String }
@main struct Checks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func main() throws {
        var groups = 0
        let legacy: [Gemma4ForwardTarget] = [.fullReference,.stage(0),.stage(1)]
        for target in legacy {
            try require(selected(.init(outputCount:16,target:target)) == legacy,"O16 all-three targets changed")
            groups += 1
        }
        for prompt in [128,4096] {
            try require(Gemma4BenchmarkOutputEnvelope.allows(outputCount:128,mode:"full",promptCount:prompt,
                chunkSize:64,cut:7,residualDType:"bfloat16"),"Actual O128 job envelope refused")
            try require(selected(.init(outputCount:128,target:.fullReference)) == [.fullReference],"O128 described forbidden stage")
            groups += 1
        }
        for mode in ["stage0","stage1"] {
            try require(!Gemma4BenchmarkOutputEnvelope.allows(outputCount:128,mode:mode,promptCount:128,
                chunkSize:64,cut:7,residualDType:"bfloat16"),"O128 stage admission widened")
            groups += 1
        }
        for output in [127,129] {
            try require(!Gemma4BenchmarkOutputEnvelope.allows(outputCount:output,mode:"full",promptCount:128,
                chunkSize:64,cut:7,residualDType:"bfloat16"),"Unbounded output admitted")
            groups += 1
        }
        try require(groups == 9,"Expected exactly nine checks")
        print("description-selection: \(groups) groups passed")
    }
}
