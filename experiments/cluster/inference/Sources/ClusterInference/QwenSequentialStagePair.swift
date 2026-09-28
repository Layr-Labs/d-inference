import MLX

/// Initial correctness driver core: finish and commit stage zero, make an
/// explicit byte-preserving owned copy, then finish and commit stage one.
/// One boundary is in flight; no transfer/compute overlap or sampling occurs.
final class QwenSequentialStagePair {
    let first: QwenLayerStageSession
    let second: QwenLayerStageSession

    init(first: QwenLayerStageSession, second: QwenLayerStageSession) throws {
        guard first.identity.stageIndex == 0, second.identity.stageIndex == 1,
            first.request == second.request,
            first.identity.requestFingerprint == second.identity.requestFingerprint,
            first.identity.artifactAggregateSHA256 == second.identity.artifactAggregateSHA256,
            first.identity.storageCommitmentSHA256 == second.identity.storageCommitmentSHA256,
            first.identity.bf16ConversionEnabled == second.identity.bf16ConversionEnabled,
            first.identity.sourceConfigurationSHA256 == second.identity.sourceConfigurationSHA256,
            first.identity.planFingerprint == second.identity.planFingerprint,
            first.identity.activationDType == second.identity.activationDType,
            first.committedTokens == 0, second.committedTokens == 0,
            !first.isClosed, !second.isClosed else { throw ProbeError("Sequential pair requires two fresh matching stage sessions") }
        self.first = first; self.second = second
    }

    func prefillChunk(_ tokens: [Int], final: Bool, check: () throws -> Void) throws -> QwenLayerStageOutput {
        try run { offset in
            guard case .hidden(let boundary) = try first.prefillChunk(tokens, offset: offset, final: final, check: check) else {
                throw ProbeError("Stage zero did not return a full residual boundary")
            }
            let copied = try boundary.ownedCopy(check: check)
            return try second.prefillChunk(tokens, offset: offset, final: final, incoming: copied, check: check)
        }
    }

    func decode(_ token: Int, check: () throws -> Void) throws -> QwenLayerStageOutput {
        try run { offset in
            guard case .hidden(let boundary) = try first.decode(token, offset: offset, check: check) else {
                throw ProbeError("Stage zero did not return a decode residual boundary")
            }
            let copied = try boundary.ownedCopy(check: check)
            return try second.decode(token, offset: offset, incoming: copied, check: check)
        }
    }

    private func run(forward: (Int) throws -> QwenLayerStageOutput) throws -> QwenLayerStageOutput {
        do {
            guard first.committedTokens == second.committedTokens else { throw ProbeError("Stage pair token frontiers diverged") }
            // Each native stage call and the explicit copy own their MLX scope.
            let output = try forward(first.committedTokens)
            guard first.committedTokens == second.committedTokens else { throw ProbeError("Stage pair committed different frontiers") }
            return output
        } catch {
            let primary = error
            var cleanup: [String] = []
            do { try first.cancel() } catch { cleanup.append(String(describing: error)) }
            do { try second.cancel() } catch { cleanup.append(String(describing: error)) }
            if !cleanup.isEmpty { throw ProbeError("Stage pair failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))") }
            throw primary
        }
    }

    func close() throws {
        var errors: [String] = []
        do { try first.close() } catch { errors.append(String(describing: error)) }
        do { try second.close() } catch { errors.append(String(describing: error)) }
        if !errors.isEmpty { throw ProbeError("Stage pair retirement: " + errors.joined(separator: "; ")) }
    }
}
