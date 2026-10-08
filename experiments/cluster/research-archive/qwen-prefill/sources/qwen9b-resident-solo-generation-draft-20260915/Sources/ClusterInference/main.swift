import Darwin
import Foundation

@main
struct Main {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--mode", "qwen-resident-solo-generation-check"] {
                try emitJSON(checkQwenResidentSoloGeneration())
                return
            }
            try QwenResidentSoloCLI(arguments: arguments).run()
        } catch {
            log("resident-solo-generation: \(error)")
            exit(1)
        }
    }
}
