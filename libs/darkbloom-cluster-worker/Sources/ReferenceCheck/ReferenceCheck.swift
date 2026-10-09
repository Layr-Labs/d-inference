import DarkbloomClusterPrompt
import DarkbloomClusterQualification
import DarkbloomClusterRuntime
import Darwin
import Foundation

// One Mac, the real artifact, no collective: runs a qualification request
// through both stages in one process and writes a reference report for the
// comparator. Stage 0 and stage 1 are the stages a two-Mac pair would run at
// the same cut, with the same chunking and the same greedy selection.
//
// The arithmetic environment must already be set, exactly as for the worker:
//   DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1

@main enum ReferenceCheck {
    static func main() async {
        do {
            var fields: [String: String] = [:]
            let arguments = Array(CommandLine.arguments.dropFirst())
            let names = ["--model-dir", "--request", "--stage-cut", "--report", "--deadline-seconds"]
            guard arguments.count % 2 == 0 else { throw Failure(usage) }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                guard names.contains(arguments[index]), fields[arguments[index]] == nil else {
                    throw Failure("Unknown or repeated argument \(arguments[index])\n" + usage)
                }
                fields[arguments[index]] = arguments[index + 1]
            }
            guard let model = fields["--model-dir"], model.hasPrefix("/"),
                  let requestPath = fields["--request"], let reportPath = fields["--report"],
                  let cut = fields["--stage-cut"].flatMap(Int.init),
                  let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds) else {
                throw Failure(usage)
            }
            let request = try QualificationRequest.read(URL(fileURLWithPath: requestPath))
            let reportURL = URL(fileURLWithPath: reportPath)
            guard !FileManager.default.fileExists(atPath: reportURL.path) else {
                throw Failure("Report \(reportURL.lastPathComponent) already exists; a report is never overwritten")
            }
            let modelDirectory = URL(fileURLWithPath: model)
            // The artifact's configuration selects the registered model; the
            // request must have been written for that model and the cut must be
            // one of its cuts, before anything is hashed or loaded.
            let registered = try QwenResidentCapabilityMetadata.registeredModel(
                configuration: QualificationFiles.read(modelDirectory.appendingPathComponent("config.json"), maximumBytes: 1 << 20))
            guard request.modelID == registered.runtimeModelID, request.profileID == registered.profileID else {
                throw Failure("The request is for \(request.modelID); the artifact in --model-dir is \(registered.runtimeModelID)")
            }
            guard registered.supportedCuts.contains(cut) else {
                throw Failure("--stage-cut must be one of " + registered.supportedCuts.map(String.init).joined(separator: ", "))
            }
            let started = DispatchTime.now().uptimeNanoseconds
            // Covers a native call that never returns; nothing is released by it.
            // The thread is the bound that is relied on: an alarm alone did not
            // end a process spinning in a native loop on real hardware.
            signal(SIGALRM) { _ in Darwin._exit(124) }
            alarm(UInt32(seconds + 5))
            try ProcessDeadline.arm(uptimeNanoseconds: started + UInt64(seconds + 5) * 1_000_000_000, status: 124)
            let result = try QwenStagedGenerationReference.run(modelDirectory: modelDirectory, stageCut: cut,
                request: .init(requestID: request.requestUUID, promptTokenIDs: request.promptTokenIDs,
                    stopTokenIDs: request.stopTokenIDs, chunkSize: request.chunkSize, outputCount: request.outputCount),
                deadlineUptimeNanoseconds: started + UInt64(seconds) * 1_000_000_000)
            alarm(0)
            let total = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

            var identity = QualificationIdentity(request: request, stageCut: cut, prefillSchedule: "serial_v1",
                artifactSHA256: result.artifactSHA256, configurationSHA256: result.configurationSHA256,
                planSHA256: result.planSHA256)
            identity.requestFingerprint = result.requestFingerprint
            identity.profileFingerprint = result.profileFingerprint
            identity.stageSHA256 = result.stageSHA256
            identity.storageCommitmentSHA256 = result.storageCommitmentSHA256
            identity.arithmeticSHA256 = result.arithmeticSHA256
            let evidence = QualificationEvidence(selectedTokenIDs: result.selectedTokenIDs,
                finishReason: result.finishReason, completedFrames: result.completedFrames,
                committedTokens: result.committedTokens,
                steps: result.steps.map {
                    .init(ordinal: $0.ordinal, frameSequence: $0.frameSequence, committedTokens: $0.committedTokens,
                          tokenID: $0.tokenID, topTokenIDs: $0.topTokenIDs, topLogits: $0.topLogits,
                          maximumTieCount: $0.maximumTieCount, rowSHA256: $0.rowSHA256)
                },
                finalLogits: .init(shape: result.finalLogitsShape, dtype: result.finalLogitsDType,
                    byteCount: result.finalLogitsByteCount, logicalBytesSHA256: result.finalLogitsSHA256,
                    values: result.finalLogits),
                stateEntries: result.stateEntries.map {
                    .init(globalLayerIndex: $0.globalLayerIndex, component: $0.component, shape: $0.shape,
                          dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256)
                }, stateSHA256: result.stateSHA256)
            // The same history in the form each rank's recording worker writes it,
            // read back with the pair tool's own reader and joined. If that does
            // not reproduce this report's evidence, the two tools disagree about
            // the record and a later pair comparison would be meaningless.
            let joined = try PairEvidence.join(try result.rankRecords.enumerated().map { try PairEvidence.decode($1, rank: $0) })
            guard joined.evidence.selectedTokenIDs == evidence.selectedTokenIDs,
                  joined.evidence.finishReason == evidence.finishReason,
                  joined.evidence.completedFrames == evidence.completedFrames,
                  joined.evidence.committedTokens == evidence.committedTokens,
                  joined.evidence.finalLogits == evidence.finalLogits,
                  joined.evidence.stateEntries == evidence.stateEntries,
                  joined.evidence.stateSHA256 == evidence.stateSHA256,
                  joined.identity.requestFingerprint == identity.requestFingerprint,
                  joined.identity.profileFingerprint == identity.profileFingerprint,
                  joined.identity.planSHA256 == identity.planSHA256,
                  joined.identity.stageSHA256 == identity.stageSHA256,
                  joined.identity.storageCommitmentSHA256 == identity.storageCommitmentSHA256,
                  joined.identity.arithmeticSHA256 == identity.arithmeticSHA256,
                  joined.identity.artifactSHA256 == identity.artifactSHA256,
                  joined.identity.configurationSHA256 == identity.configurationSHA256,
                  joined.identity.requestID == identity.requestID else {
                throw Failure("The per-rank records of this run do not join into its own evidence")
            }
            let prefill = Double(result.prefillNanoseconds) / 1e9, decode = Double(result.decodeNanoseconds) / 1e9
            let decodeFrames = result.selectedTokenIDs.count - 1
            let timing = ReferenceTiming(stageLoadSeconds: result.stageLoadSeconds, prefillSeconds: prefill,
                prefillTokensPerSecond: Double(request.promptTokenIDs.count) / prefill, decodeSeconds: decode,
                decodeTokensPerSecond: decodeFrames > 0 && decode > 0 ? Double(decodeFrames) / decode : nil,
                requestWallSeconds: Double(result.requestWallNanoseconds) / 1e9, totalSeconds: total,
                note: "Same-process clock. Prefill and decode are the summed frame times: stage 0 forward, residual copy "
                    + "and digest, stage 1 forward and token selection. They exclude loading and the per-token copy of "
                    + "the complete row to the CPU, which the request wall time includes. Not a serving measurement.")
            let memory = ReferenceMemory(activeBytesBefore: result.activeBytesBefore,
                activeBytesLoaded: result.activeBytesLoaded, peakBytes: result.peakBytes,
                activeBytesAfterRelease: result.activeBytesAfterRelease,
                cacheBytesAfterRelease: result.cacheBytesAfterRelease, loadedTensorBytes: result.loadedTensorBytes,
                stageModelsReleased: result.stageModelsReleased)
            let executable = Bundle.main.executableURL
            let tokenizer = try? await PromptTokenizer.load(modelDirectory: modelDirectory)
            let report = ReferenceReport(identity: identity, evidence: evidence,
                host: .local(role: "single host"),
                binarySHA256: executable.flatMap { try? QualificationHash.file($0, maximumBytes: 1 << 30) },
                metallibSHA256: executable.flatMap {
                    try? QualificationHash.file($0.deletingLastPathComponent().appendingPathComponent("mlx.metallib"), maximumBytes: 1 << 30)
                }, timing: timing, memory: memory, promptSource: request.promptSource,
                decodedOutput: tokenizer?.decode(result.selectedTokenIDs),
                senderCheck: .init(refusedFrames: result.unownedResidualFrames, firstRefused: result.firstUnownedResidual.map {
                    .init(frameSequence: $0.frameSequence, phase: $0.phase, tokenCount: $0.tokenCount, byteCount: $0.byteCount,
                          allocatedBytes: $0.allocatedBytes, allocationBound: $0.allocationBound, dataOffset: $0.dataOffset,
                          dataElements: $0.dataElements, elementCount: $0.elementCount, isUnique: $0.isUnique,
                          isRowContiguous: $0.isRowContiguous, ownedAfterGPUSynchronize: $0.ownedAfterGPUSynchronize)
                }))
            try QualificationFiles.writeNew(QualificationReportFiles.encode(report), to: reportURL)

            let released = result.stageModelsReleased.allSatisfy { $0 }
            var summary: [String: Any] = [
                "report": reportURL.lastPathComponent, "stageCut": cut, "promptTokens": request.promptTokenIDs.count,
                "chunkSize": request.chunkSize, "selectedTokens": result.selectedTokenIDs.count,
                "finishReason": result.finishReason, "selectedTokenIDsSHA256": QualificationHash.tokenIDs(result.selectedTokenIDs),
                "finalRowSHA256": result.finalLogitsSHA256, "stateSHA256": result.stateSHA256,
                "prefillTokensPerSecond": timing.prefillTokensPerSecond, "totalSeconds": total,
                "activeBytesLoaded": result.activeBytesLoaded, "activeBytesAfterRelease": result.activeBytesAfterRelease,
                "cacheBytesAfterRelease": result.cacheBytesAfterRelease, "stageModelsReleased": released,
                "rankRecordsJoinToThisEvidence": true,
                "residualFramesAPairSenderWouldRefuse": result.unownedResidualFrames.count,
            ]
            if !result.unownedResidualFrames.isEmpty {
                FileHandle.standardError.write(Data(("darkbloom-cluster-reference: \(result.unownedResidualFrames.count) stage 0 "
                    + "residual(s) would be refused by a pair's sender, first at frame \(result.unownedResidualFrames[0])\n").utf8))
            }
            // The host memory gate's own record of this run: how many decisions,
            // the tightest one, and whether any admission needed file cache.
            summary["resourceAdmission"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.resourceAdmission))
            if let rate = timing.decodeTokensPerSecond { summary["decodeTokensPerSecond"] = rate }
            if let text = report.decodedOutput { summary["decodedOutput"] = text }
            print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            Darwin.exit(released ? 0 : 2)
        } catch {
            FileHandle.standardError.write(Data("darkbloom-cluster-reference: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    static let usage = "usage: --model-dir /ABS/MODEL --request REQUEST.json --stage-cut CUT --report NEW-REPORT.json [--deadline-seconds 10...300]\n"
        + "  CUT is one of the registered model's cuts: 4|8|12|16 for the 9B, 4|8|...|60 for the 27B"

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
