import Darwin
import Foundation

/// Private reference executable; the original broad benchmark Main is retained
/// outside this source overlay and is not changed in any existing build.
@main
struct Main {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--mode", "qwen-registered-full-generation-reference-check"] {
                try emitJSON(checkQwenFullGenerationReferenceEntry())
                return
            }
            try QwenFullGenerationReferenceCLI(arguments: arguments).run()
        } catch {
            log("full-generation-reference: \(error)")
            exit(1)
        }
    }
}
