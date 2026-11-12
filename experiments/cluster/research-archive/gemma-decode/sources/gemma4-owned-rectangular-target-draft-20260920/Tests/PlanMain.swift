import Foundation

@main struct AttentionPlanMain {
    static func main() throws {
        let groups = try AttentionVerificationPlanCheck.run()
        let data = try JSONSerialization.data(withJSONObject: ["groups": groups, "gpuExecuted": false,
            "modelExecuted": false], options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
