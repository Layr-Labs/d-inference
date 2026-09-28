import MLX
import MLXLMCommon

/// One ordered request owns all mutable model state. Both paths return one
/// vocabulary row; token selection and rank coordination stay in the caller.
protocol RequestModelSession: AnyObject {
    func prefill(_ prompt: [Int], check: () throws -> Void) throws -> MLXArray
    func decode(_ token: Int, check: () throws -> Void) throws -> MLXArray
    func close() throws
}

func makeRequestModelSession(loaded: LoadedModel, options: Options) -> any RequestModelSession {
    switch options.executionPath {
    case .ordinary: OrdinaryRequestSession(loaded: loaded, options: options)
    case .cbv2Contiguous: CBv2RequestExecution(loaded: loaded, options: options)
    }
}

private final class OrdinaryRequestSession: RequestModelSession {
    let loaded: LoadedModel
    let options: Options
    let cache: [KVCache]
    var state: LMOutput.State?

    init(loaded: LoadedModel, options: Options) {
        self.loaded = loaded; self.options = options
        cache = loaded.model.newCache(parameters: nil)
    }

    func prefill(_ prompt: [Int], check: () throws -> Void) throws -> MLXArray {
        let output: LMOutput
        if options.gemmaDiagnostic {
            output = try gemmaDiagnosticPrefill(loaded: loaded, prompt: prompt, cache: cache,
                                                chunkSize: options.chunkSize, check: check)
        } else {
            let input = LMInput(tokens: MLXArray(prompt))
            switch try loaded.model.prepare(input, cache: cache, windowSize: options.chunkSize) {
            case .tokens(let remaining):
                output = loaded.model(remaining[text: .newAxis], cache: cache, state: nil)
            case .logits(let prepared): output = prepared
            }
        }
        state = output.state
        return output.logits[0, -1, 0...]
    }

    func decode(_ token: Int, check: () throws -> Void) throws -> MLXArray {
        let input = LMInput.Text(tokens: MLXArray([token]).reshaped(1, 1))
        let output = loaded.model(input, cache: cache, state: state)
        if options.gemmaDiagnostic {
            try evaluateGemmaDiagnostic(output, trace: loaded.gemmaTrace, check: check)
        }
        state = output.state
        return output.logits[0, -1, 0...]
    }

    func close() throws {}
}

private final class CBv2RequestExecution: RequestModelSession {
    let loaded: LoadedModel
    let options: Options
    var session: CBv2RequestSession?

    init(loaded: LoadedModel, options: Options) {
        self.loaded = loaded; self.options = options
    }

    func prefill(_ prompt: [Int], check: () throws -> Void) throws -> MLXArray {
        guard session == nil else { throw ProbeError("CBv2 request prefill was already started") }
        // Request-owned backend/state construction is inside the prefill clock.
        let created = try CBv2RequestSession(loaded: loaded, promptCount: prompt.count,
                                             outputCount: options.decodeCount)
        session = created
        try check()
        var last: MLXArray?
        for start in stride(from: 0, to: prompt.count, by: options.chunkSize) {
            let end = min(start + options.chunkSize, prompt.count)
            let output = try created.prefillChunk(Array(prompt[start..<end]),
                                                  final: end == prompt.count, check: check)
            if end == prompt.count { last = output }
        }
        guard let last, last.shape == [1, loaded.vocabularySize] else {
            throw ProbeError("CBv2 prefill did not return one complete vocabulary row")
        }
        return last[0]
    }

    func decode(_ token: Int, check: () throws -> Void) throws -> MLXArray {
        guard let session else { throw ProbeError("CBv2 decode has no request state") }
        let output = try session.decode(token, check: check)
        guard output.shape == [1, loaded.vocabularySize] else {
            throw ProbeError("CBv2 decode did not return one complete vocabulary row")
        }
        return output[0]
    }

    func close() throws { try session?.close() }
}
