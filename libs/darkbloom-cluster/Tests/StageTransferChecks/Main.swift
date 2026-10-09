import Darwin
import Foundation

@main enum StageTransferCheck {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ProbeError("usage: check /ABS/qwen-retained-inputs.json")
            }
            let inputs = try RetainedQwenInputs(file: URL(fileURLWithPath: CommandLine.arguments[1]))
            let checks = StageTransferChecks()
            try checkContentInventoryCodec(inputs, checks)
            print(#"{"passed":true,"accepted":\#(checks.accepted.count),"refused":\#(checks.refused.count),"#
                + #""modelExecution":false,"mlxUsed":false,"networkUsed":false}"#)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
