import DarkbloomClusterRuntime
import Foundation

// One Mac, the real artifact, no model and no collective: verifies every file
// against the registered manifest, hashes each stored tensor a stage can own,
// and writes the canonical content inventory. Its SHA-256 is what the
// registered specification pins; for a model that already has a pin, the exit
// status says whether this artifact reproduces it.
//
//   darkbloom-cluster-stage-check content-inventory --model-dir /ABS/MODEL \
//     --output /ABS/inventory.txt [--swift-output /ABS/Generated.swift]
//
// Neither output file is ever overwritten. No arithmetic environment is needed:
// nothing is evaluated.

enum ContentInventoryCommand {
    static let name = "content-inventory"

    /// Returns the exit status: 0 when the artifact reproduces the registered
    /// pin or the model has none yet, 3 when it differs from the pin.
    static func run(_ arguments: [String]) throws -> Int32 {
        let fields = try StageCheckArguments.parse(arguments, allowed: ["--model-dir", "--output", "--swift-output", "--deadline-seconds"])
        guard let model = fields["--model-dir"], model.hasPrefix("/"),
              let output = fields["--output"], output.hasPrefix("/"),
              fields["--swift-output"]?.hasPrefix("/") ?? true,
              let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds) else {
            throw StageLoadCheck.Failure("usage: content-inventory --model-dir /ABS/PATH --output /ABS/FILE "
                + "[--swift-output /ABS/FILE] [--deadline-seconds 10...300]")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
        let generated = try QwenContentInventoryGenerator.run(modelDirectory: URL(fileURLWithPath: model),
                                                             deadlineUptimeNanoseconds: deadline)
        try generated.document.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        if let swift = fields["--swift-output"] {
            try Data(generated.swiftSource.utf8).write(to: URL(fileURLWithPath: swift), options: .withoutOverwriting)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(generated.receipt), as: UTF8.self))
        return generated.receipt.matchesRegisteredPin == false ? 3 : 0
    }
}
