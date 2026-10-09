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
// and, for a model with routed experts, also MLX_GATHER_QMM_EXPERT_SLICES=trust.

@main enum ReferenceCheck {
    static func main() async {
        do {
            var fields: [String: String] = [:]
            let arguments = Array(CommandLine.arguments.dropFirst())
            let names = ["--model-dir", "--request", "--stage-cut", "--report", "--deadline-seconds",
                         "--handoff", "--handoff-segment-bytes", "--handoff-corrupt-segment", "--serve"]
            guard arguments.count % 2 == 0 else { throw Failure(usage) }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                guard names.contains(arguments[index]), fields[arguments[index]] == nil else {
                    throw Failure("Unknown or repeated argument \(arguments[index])\n" + usage)
                }
                fields[arguments[index]] = arguments[index + 1]
            }
            if fields["--serve"] != nil {
                guard fields["--serve"] == "yes", fields["--request"] == nil, fields["--report"] == nil,
                      fields["--handoff"] == nil, let model = fields["--model-dir"], model.hasPrefix("/"),
                      let cut = fields["--stage-cut"].flatMap(Int.init),
                      let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds) else {
                    throw Failure(usage)
                }
                // As below: the artifact's configuration selects the registered
                // model, and the cut must be one of that model's cuts.
                let served = try QwenResidentCapabilityMetadata.registeredModel(configuration: QualificationFiles.read(
                    URL(fileURLWithPath: model).appendingPathComponent("config.json"), maximumBytes: 1 << 20))
                guard served.supportedCuts.contains(cut) else {
                    throw Failure("--stage-cut must be one of " + served.supportedCuts.map(String.init).joined(separator: ", "))
                }
                try serve(modelDirectory: URL(fileURLWithPath: model), cut: cut, seconds: seconds)
            }
            guard let model = fields["--model-dir"], model.hasPrefix("/"),
                  let requestPath = fields["--request"], let reportPath = fields["--report"],
                  let cut = fields["--stage-cut"].flatMap(Int.init),
                  let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds),
                  ["in-process", nil].contains(fields["--handoff"]) else {
                throw Failure(usage)
            }
            var handoff: QwenStagedGenerationReference.Handoff?
            if fields["--handoff"] != nil {
                var value = QwenStagedGenerationReference.Handoff()
                if let text = fields["--handoff-segment-bytes"] {
                    guard let bytes = Int(text), (4096...(16 * 1024 * 1024)).contains(bytes) else {
                        throw Failure("--handoff-segment-bytes must be 4096...16777216")
                    }
                    value.maximumSegmentBytes = bytes
                }
                if let text = fields["--handoff-corrupt-segment"] {
                    guard let index = Int(text), index >= 0 else { throw Failure("--handoff-corrupt-segment must be a segment index") }
                    value.corruptSegment = index
                }
                handoff = value
            } else if fields["--handoff-segment-bytes"] != nil || fields["--handoff-corrupt-segment"] != nil {
                throw Failure("Hand-off options need --handoff in-process")
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
            let result: QwenStagedGenerationReference.Result
            do {
                result = try QwenStagedGenerationReference.run(modelDirectory: modelDirectory, stageCut: cut,
                    request: .init(requestID: request.requestUUID, promptTokenIDs: request.promptTokenIDs,
                        stopTokenIDs: request.stopTokenIDs, chunkSize: request.chunkSize, outputCount: request.outputCount),
                    deadlineUptimeNanoseconds: started + UInt64(seconds) * 1_000_000_000, handoff: handoff)
            } catch let refusal as QwenStagedGenerationReference.HandoffRefusal {
                // The outcome a fault run asks for: the adopting side refused
                // the state, and nothing was left allocated afterwards.
                alarm(0)
                let released = refusal.requestStatesRetired && refusal.stageModelsReleased.allSatisfy { $0 }
                let summary: [String: Any] = [
                    "schema": "darkbloom_cluster_reference_handoff_refusal_v1", "handoffRefused": true,
                    "injectedFault": handoff?.corruptSegment.map { "bit flipped in segment \($0)" } ?? "none",
                    "reason": refusal.reason, "stageCut": cut, "promptTokens": request.promptTokenIDs.count,
                    "requestStatesRetired": refusal.requestStatesRetired,
                    "stageModelsReleased": refusal.stageModelsReleased.allSatisfy { $0 },
                    "activeBytesAfterRelease": refusal.activeBytesAfterRelease,
                    "cacheBytesAfterRelease": refusal.cacheBytesAfterRelease,
                ]
                var data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
                data.append(10)
                try QualificationFiles.writeNew(data, to: reportURL)
                print(String(decoding: data, as: UTF8.self), terminator: "")
                Darwin.exit(handoff?.corruptSegment != nil && released ? 0 : 2)
            }
            alarm(0)
            if handoff?.corruptSegment != nil {
                throw Failure("A corrupted hand-off segment was adopted without refusal")
            }
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
                }),
                handoff: result.handoff.map {
                    .init(entries: $0.entries, segments: $0.segments, logicalBytes: $0.logicalBytes,
                          headerBytes: $0.headerBytes, stateSHA256: $0.stateSHA256, seconds: Double($0.nanoseconds) / 1e9,
                          exportSeconds: Double($0.exportNanoseconds) / 1e9,
                          transferSeconds: Double($0.transferNanoseconds) / 1e9,
                          adoptionSeconds: Double($0.adoptionNanoseconds) / 1e9,
                          producerStateRetired: $0.producerStateRetired, activeBytesBefore: $0.activeBytesBefore,
                          activeBytesAfter: $0.activeBytesAfter)
                })
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
            if let handoff = result.handoff {
                summary["handoffEntries"] = handoff.entries; summary["handoffSegments"] = handoff.segments
                summary["handoffLogicalBytes"] = handoff.logicalBytes
                summary["handoffSeconds"] = Double(handoff.nanoseconds) / 1e9
                summary["handoffExportSeconds"] = Double(handoff.exportNanoseconds) / 1e9
                summary["handoffTransferSeconds"] = Double(handoff.transferNanoseconds) / 1e9
                summary["handoffAdoptionSeconds"] = Double(handoff.adoptionNanoseconds) / 1e9
                summary["handoffProducerStateRetired"] = handoff.producerStateRetired
            }
            if let text = report.decodedOutput { summary["decodedOutput"] = text }
            print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            Darwin.exit(released ? 0 : 2)
        } catch let failure as QwenResidentReleasedFailure {
            // A run that began and failed: the failure and what was still held
            // after release go to standard output as one record.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let record = try? encoder.encode(failure) { print(String(decoding: record, as: UTF8.self)) }
            FileHandle.standardError.write(Data("darkbloom-cluster-reference: \(failure)\n".utf8))
            Darwin.exit(1)
        } catch {
            FileHandle.standardError.write(Data("darkbloom-cluster-reference: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    static let usage = """
        usage: --model-dir /ABS/MODEL --request REQUEST.json --stage-cut CUT --report NEW-REPORT.json [--deadline-seconds 10...300]
                 [--handoff in-process [--handoff-segment-bytes 4096...16777216] [--handoff-corrupt-segment INDEX]]
               --model-dir /ABS/MODEL --stage-cut CUT --serve yes [--deadline-seconds 10...300]
          CUT is one of the registered model's cuts:

        """ + "    " + QwenResidentCapabilityMetadata.registeredCutsUsage.replacingOccurrences(of: "\n", with: "\n    ") + "\n"

    /// One event per line on standard output, written at once.
    static func emit(_ event: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    struct ServeCommand: Decodable {
        let command: String
        let requestID: String?
        let promptTokenIDs: [Int]?
        let stopTokenIDs: [Int]?
        let chunkSize: Int?
        let outputCount: Int?
    }

    /// `--serve yes`: both stages loaded once, then one request per `run` line
    /// on standard input, each selected token reported as it is chosen. For a
    /// driver that times one Mac alone on its own clock, as it times a pair.
    /// Standard input ending, or a `shutdown` line, releases and exits.
    static func serve(modelDirectory: URL, cut: Int, seconds: Int) throws -> Never {
        let started = DispatchTime.now().uptimeNanoseconds
        signal(SIGPIPE, SIG_IGN)
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(UInt32(seconds + 5))
        try ProcessDeadline.arm(uptimeNanoseconds: started + UInt64(seconds + 5) * 1_000_000_000, status: 124)
        let release = try QwenStagedGenerationReference.serve(modelDirectory: modelDirectory, stageCut: cut,
            deadlineUptimeNanoseconds: started + UInt64(seconds) * 1_000_000_000,
            ready: {
                try emit(["event": "ready", "stageLoadSeconds": $0.stageLoadSeconds,
                          "activeBytesBefore": $0.activeBytesBefore, "activeBytesLoaded": $0.activeBytesLoaded])
            },
            next: {
                // `prepare` carries the request and is answered; `start` then
                // begins it. A pair is driven the same way: the prompt travels
                // with the reservation, and the clock starts at the start command.
                guard let line = readLine(strippingNewline: true), !line.isEmpty else { return nil }
                let command = try JSONDecoder().decode(ServeCommand.self, from: Data(line.utf8))
                if command.command == "shutdown" { return nil }
                guard command.command == "prepare", let text = command.requestID, let id = UUID(uuidString: text),
                      let prompt = command.promptTokenIDs, let chunk = command.chunkSize, let count = command.outputCount else {
                    throw Failure("Unknown or incomplete serve command")
                }
                try emit(["event": "prepared", "requestID": text])
                guard let next = readLine(strippingNewline: true),
                      let start = try? JSONDecoder().decode(ServeCommand.self, from: Data(next.utf8)),
                      start.command == "start", start.requestID == text else {
                    throw Failure("A prepared request must be followed by its start command")
                }
                return QwenStagedGenerationReference.Request(requestID: id, promptTokenIDs: prompt,
                    stopTokenIDs: command.stopTokenIDs ?? [], chunkSize: chunk, outputCount: count)
            },
            token: { try emit(["event": "token", "ordinal": $0, "tokenID": $1]) },
            finished: {
                try emit(["event": "finished", "reason": $0.finishReason, "tokens": $0.selectedTokenIDs.count,
                          "firstTokenNanoseconds": $0.firstTokenNanoseconds, "lastTokenNanoseconds": $0.lastTokenNanoseconds,
                          "retiredNanoseconds": $0.retiredNanoseconds, "residualCopies": $0.residualCopies,
                          "activeBytesDuringRequest": $0.activeBytesDuringRequest,
                          "activeBytesAfterRetirement": $0.activeBytesAfterRetirement])
            })
        alarm(0)
        let released = release.stageModelsReleased.allSatisfy { $0 }
        try emit(["event": "released", "requests": release.requests, "stageModelsReleased": released,
                  "activeBytesAfterRelease": release.activeBytesAfterRelease,
                  "cacheBytesAfterRelease": release.cacheBytesAfterRelease, "peakBytes": release.peakBytes])
        Darwin.exit(released ? 0 : 2)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
