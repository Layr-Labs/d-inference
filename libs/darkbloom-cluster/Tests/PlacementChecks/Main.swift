import Darwin
import DarkbloomClusterPlacement
import Foundation

@main enum PlacementCheck {
    static func main() {
        do {
            // `check tool ...` runs the plan command's own code without a device
            // sampler, and `check constructed-profile GIB CHIP OSBUILD` prints the
            // profile of an idle constructed Mac; both are for working on a
            // plan away from the Macs it is for, never evidence about one.
            if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "tool" {
                print(try ClusterPlacementTool.run(Array(CommandLine.arguments.dropFirst(2)), sampleDevice: {
                    throw ProbeError("This build has no device sampler; pass every device as --peer LABEL=PROFILE.json")
                }))
                return
            }
            if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "constructed-profile",
               let size = Double(CommandLine.arguments[2]) {
                let profile = try SyntheticMac.idle(size).profile(chip: CommandLine.arguments[3])
                var object = try JSONSerialization.jsonObject(with: profile.encoded()) as! [String: Any]
                object["osBuild"] = CommandLine.arguments[4]
                print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            guard CommandLine.arguments.count == 2 else {
                throw ProbeError("usage: check /ABS/qwen-retained-inputs.json")
            }
            let inputs = try JSONDecoder().decode(RetainedQwenInputs.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let checks = PlacementChecks()
            checkGateAgreement(checks)
            try checkLayoutBuilder(checks)
            let layouts = try checkRegisteredLayouts(inputs, checks)
            try checkDeviceMixes(layouts.nine, layouts.twentySeven, checks)
            try checkSpeed(layouts.twentySeven, checks)
            try checkProfiles(checks)
            guard checks.failures.isEmpty else {
                for failure in checks.failures { fputs("FAIL: \(failure)\n", stderr) }
                fputs("\(checks.failures.count) failed, \(checks.passed.count) passed\n", stderr)
                exit(1)
            }
            let output: [String: Any] = ["passed": true, "checks": checks.passed, "checkCount": checks.passed.count,
                "modelExecution": false, "mlxUsed": false, "networkUsed": false, "hardwarePass": false]
            let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
            try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
