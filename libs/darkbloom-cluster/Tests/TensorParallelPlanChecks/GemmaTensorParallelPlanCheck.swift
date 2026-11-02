import Foundation

// Model-free checks of `Gemma4TensorParallelPlan` against the registered
// Gemma 4 26B QAT 4-bit artifact's safetensors headers (no payload) and the
// 8-bit artifact's shapes derived from them: every text tensor has the shape
// the plan expects; the two ranks' cuts cover it exactly once (rows, owned
// channels) or replicate it, with equal local shapes; the text bytes equal
// the registered totals; vision, unknown and misaligned inputs are refused.

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) rethrows {
    if try !condition() { failures += 1; print("FAIL: \(message())") }
}
func refuses(_ label: String, _ body: () throws -> Void) {
    do { try body(); failures += 1; print("FAIL: expected a refusal: \(label)") } catch {}
}

@main enum GemmaTensorParallelPlanCheck {
    static func main() throws {
        let inputs = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var tensors: [(name: String, shape: [Int], dtype: String)] = []
        for index in 1 ... 3 {
            let url = inputs.appendingPathComponent("model-0000\(index)-of-00003.safetensors.header.json")
            let header = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            for (name, value) in header where name != "__metadata__" {
                let entry = value as! [String: Any]
                tensors.append((name, entry["shape"] as! [Int], entry["dtype"] as! String))
            }
        }
        func configuration(bits: Int) throws -> [String: Any] {
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: inputs.appendingPathComponent("config.json"))) as! [String: Any]
            for key in ["quantization", "quantization_config"] {
                var table = root[key] as! [String: Any]
                table["bits"] = bits
                root[key] = table
            }
            return root
        }
        for (bits, registered) in [(4, 14_467_688_508), (8, 26_810_869_820)] {
            let plan = try Gemma4TensorParallelPlan(configuration: try configuration(bits: bits))
            var text = 0, ranks = [0, 0], vision = 0
            for tensor in tensors {
                let width = tensor.dtype == "U32" ? 4 : 2
                if !tensor.name.hasPrefix("language_model.") {
                    check(Gemma4TensorParallelPlan.isVisionTensor(tensor.name), "\(tensor.name) is neither text nor vision")
                    refuses("vision \(tensor.name)") { _ = try plan.cut(key: tensor.name, rank: 0) }
                    vision += 1
                    continue
                }
                let shape = bits == 4 ? tensor.shape : try plan.expectedShape(key: tensor.name)
                try check(try plan.expectedShape(key: tensor.name) == shape, "\(tensor.name): \(tensor.shape)")
                text += shape.reduce(width, *)
                let cuts = try (0 ..< 2).map { try plan.cut(key: tensor.name, rank: $0) }
                let locals = try (0 ..< 2).map { try plan.localShape(key: tensor.name, shape: shape, cut: cuts[$0]) }
                check(locals[0] == locals[1], "\(tensor.name): unequal local shapes \(locals)")
                for rank in 0 ..< 2 { ranks[rank] += locals[rank].reduce(width, *) }
                switch (cuts[0], cuts[1]) {
                case (.replicate, .replicate):
                    break
                case (.rows(let a, _, _), .rows(let b, _, _)), (.expertRows(let a, _, _), .expertRows(let b, _, _)):
                    let axis = shape.count == 3 ? 1 : 0
                    check(a.lowerBound == 0 && a.upperBound == b.lowerBound && b.upperBound == shape[axis],
                          "\(tensor.name): rows \(a) \(b) do not cover \(shape[axis]) once")
                case (.inputColumns(let a), .inputColumns(let b)), (.expertInputColumns(let a), .expertInputColumns(let b)):
                    let overlap = a.upperBound - b.lowerBound
                    check(a.lowerBound == 0 && a.count == b.count && (overlap == 0 || overlap == plan.groupSize),
                          "\(tensor.name): columns \(a) \(b)")
                default:
                    check(false, "\(tensor.name): the ranks' cuts differ in kind")
                }
            }
            check(vision == 358, "\(vision) vision tensors")
            check(text == registered, "\(bits)-bit text bytes \(text), registered \(registered)")
            check(plan.kvHeadsPerRank == (0 ..< 30).map { ($0 + 1) % 6 == 0 ? 1 : 4 }, "per-rank KV heads")
            try check(try plan.denseSplit(rank: 1).localWidth == 1088 && plan.expertSplit(rank: 0).localWidth == 384, "local widths")
            print("\(bits)-bit: \(tensors.count - vision) text tensors, \(text) bytes, \(ranks[0]) bytes per rank")
        }
        let plan = try Gemma4TensorParallelPlan(configuration: try configuration(bits: 4))
        for key in ["language_model.lm_head.weight", "language_model.model.layers.5.self_attn.v_proj.weight",
                    "language_model.model.layers.30.layer_scalar", "embed_vision.embedding_projection.weight"] {
            refuses(key) { _ = try plan.cut(key: key, rank: 0) }
        }
        for (key, value) in [("intermediate_size", 2144 as Any), ("head_dim", 36), ("num_global_key_value_heads", 1),
                             ("tie_word_embeddings", false), ("enable_moe_block", false)] {
            var root = try configuration(bits: 4)
            var text = root["text_config"] as! [String: Any]
            text[key] = value
            root["text_config"] = text
            refuses(key) { _ = try Gemma4TensorParallelPlan(configuration: root) }
        }
        print(failures == 0 ? "Gemma tensor-parallel plan checks passed" : "\(failures) Gemma plan check failures")
        exit(failures == 0 ? 0 : 1)
    }
}
