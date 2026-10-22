import Foundation

@main enum TemporaryWindowChecks {
    static func main() throws {
        var groups = 0
        func group(_ name: String, _ body: () throws -> Void) rethrows {
            try body(); groups += 1; print("PASS " + name)
        }
        func require(_ value: Bool) throws {
            if !value { throw Failure() }
        }
        func refuses(_ body: () throws -> Void) throws {
            do { try body() } catch is Gemma4ExpertTemporaryWindowError { return }
            throw Failure()
        }
        func finishLayer(_ value: inout Gemma4ExpertTemporaryWindow, frame: Int, layer: Int) throws {
            try value.begin(frame: frame, layer: layer)
            try value.inputEvaluated(); try value.exchangeCompleted(); try value.returned()
        }
        for frames in [2, 3] {
            try group("complete-\(frames)-frames") {
                var value = try Gemma4ExpertTemporaryWindow(frames: frames)
                for frame in 0..<frames {
                    for layer in 0..<30 { try finishLayer(&value, frame: frame, layer: layer) }
                }
                try value.requireComplete()
                try refuses { try value.begin(frame: frames, layer: 0) }
            }
        }
        try group("missing-layer") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try refuses { try value.begin(frame: 0, layer: 1) }
            try refuses { try value.begin(frame: 0, layer: 0) }
        }
        try group("reentry-poisons") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0)
            try refuses { try value.begin(frame: 0, layer: 0) }
            try refuses { try value.inputEvaluated() }
        }
        try group("return-before-eval-refused") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0)
            try refuses { try value.returned() }
        }
        try group("return-before-exchange-refused") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0); try value.inputEvaluated()
            try refuses { try value.returned() }
        }
        try group("exchange-before-eval-refused") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0)
            try refuses { try value.exchangeCompleted() }
        }
        try group("duplicate-exchange-refused") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0); try value.inputEvaluated(); try value.exchangeCompleted()
            try refuses { try value.exchangeCompleted() }
        }
        try group("evaluation-needs-live-layer") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try refuses { try value.inputEvaluated() }
        }
        try group("duplicate-evaluation-refused") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0); try value.inputEvaluated()
            try refuses { try value.inputEvaluated() }
        }
        try group("frame-cannot-skip-final-layer") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 3)
            for layer in 0..<29 { try finishLayer(&value, frame: 0, layer: layer) }
            try refuses { try value.begin(frame: 1, layer: 0) }
        }
        try group("old-frame-cannot-replay") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            for layer in 0..<30 { try finishLayer(&value, frame: 0, layer: layer) }
            try refuses { try value.begin(frame: 0, layer: 0) }
        }
        try group("incomplete-forward-refused") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            for layer in 0..<30 { try finishLayer(&value, frame: 0, layer: layer) }
            try refuses { try value.requireComplete() }
        }
        try group("failure-after-eval-cannot-return") {
            var value = try Gemma4ExpertTemporaryWindow(frames: 2)
            try value.begin(frame: 0, layer: 0); try value.inputEvaluated(); value.poison()
            try refuses { try value.returned() }
            try refuses { try value.requireComplete() }
        }
        try group("closed-purpose-counts") {
            for frames in [-1, 0, 1, 4, Int.max] {
                try refuses { _ = try Gemma4ExpertTemporaryWindow(frames: frames) }
            }
        }
        try group("scalar-host-charge-and-closed-envelope") {
            let policy = Gemma4ExpertTemporaryPolicy.adjacentSynchronousV1
            try require(policy.layerSlots == 2 && policy.maximumFrameTokens == 16)
            try require(2 * MemoryLayout<Gemma4ExpertTemporaryWindow>.stride <= policy.scalarHostBytes)
            try require(policy.scalarHostBytes == 4096)
        }
        print("PASS \(groups) temporary-window groups; no MLX/model/transport")
    }
    struct Failure: Error {}
}
