import Foundation

extension Gemma4ExpertPartition {
    var fingerprint: String { sha256(Data(bindingText.utf8)) }
}

enum Gemma4ExpertSelection {
    static let expertSuffixes = ["down_proj", "gate_proj", "up_proj"].flatMap { projection in
        ["biases", "scales", "weight"].map { projection + "." + $0 }
    }
    static var expertNames: Set<String> {
        Set((0..<30).flatMap { layer in expertSuffixes.map {
            "language_model.model.layers.\(layer).experts.switch_glu.\($0)"
        } })
    }

    static func make(plan: Gemma4LayerStagePlan, partition: Gemma4ExpertPartition) throws -> [Gemma4SelectedTensor] {
        let original = try Gemma4ForwardSelection.make(plan: plan, target: .fullReference)
        let expected = expertNames
        let actual = Set(original.map(\.localName).filter { $0.contains(".experts.") })
        guard actual == expected else { throw ProbeError("Gemma EP requires complete original split expert inventory") }
        let selection = TensorSelection.axis(0, try partition.ownership().expertRanges(rank: partition.rank))
        return try original.map { item in
            guard expected.contains(item.localName) else { return item }
            let suffix = String(item.localName.split(separator: ".").suffix(2).joined(separator: "."))
            let packed = suffix.hasSuffix(".weight")
            let divisor = packed ? 8 : 64
            let shape = suffix.hasPrefix("down_proj.")
                ? [128, 2816, 704 / divisor] : [128, 704, 2816 / divisor]
            guard item.source.layout.shape == shape,
                  item.source.layout.sourceDType == (packed ? "U32" : "BF16"),
                  item.source.layout.byteCount == (try QwenLongPrefillCheckedBytes.product(shape + [packed ? 4 : 2])) else {
                throw ProbeError("Gemma EP packed4/group64 source contract differs")
            }
            return try Gemma4SelectedTensor(source: item.source, localName: item.localName, selection: selection)
        }
    }
}
