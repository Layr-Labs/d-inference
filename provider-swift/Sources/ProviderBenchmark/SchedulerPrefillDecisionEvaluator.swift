import Foundation
import ProviderCore

enum SchedulerPrefillDecisionEvaluator {
    static let thresholds = SchedulerPrefillDecisionReport.EvaluationThresholds(
        minimumLiveIterations: SchedulerPrefillDecisionReport.minimumLiveIterations,
        minimumThroughputRatio: 0.95,
        minimumBurstMeanTTFTImprovement: 0.25,
        firstContentBaseMs: 10_000,
        firstContentPerPromptTokenMs: 1,
        minimum8KBurstDeadlineHits: 3)

    static func evaluate(
        mode: SchedulerPrefillDecisionReport.Mode,
        results: [SchedulerPrefillDecisionReport.Result],
        modelIdentity: SchedulerPrefillDecisionReport.ModelIdentity?,
        reproducibility: SchedulerPrefillDecisionReport.Reproducibility?,
        evidenceClass: SchedulerPrefillDecisionReport.EvidenceClass = .unsignedLocalHarness,
        signedArtifactIdentity: SchedulerPrefillDecisionReport.SignedArtifactIdentity? = nil
    ) -> SchedulerPrefillDecisionReport.Evaluation {
        let requiredWorkloads = SchedulerPrefillDecisionScenarios.qwenEvaluationWorkloads
        let groups = Dictionary(grouping: results, by: SchedulerPrefillDecisionCell.init)
        let requiredCells = requiredWorkloads.flatMap { workload in
            SchedulerPrefillDecisionScenarios.partialPrefillCaps.map {
                SchedulerPrefillDecisionCell(
                    workload: workload,
                    maxConcurrentPartialPrefills: $0)
            }
        }

        let cellCounts = requiredCells.map { groups[$0]?.count ?? 0 }
        let uniformCount = Set(cellCounts).count == 1
        let iterationCount = cellCounts.min() ?? 0
        let matrixComplete = groups.count == requiredCells.count
            && uniformCount
            && iterationCount > 0
            && requiredCells.allSatisfy { cell in
                guard let values = groups[cell],
                    values.allSatisfy({
                        $0.rows.count == $0.workload.rows.count
                    })
                else { return false }
                return Set(values.map(\.iteration)) == Set(1 ... values.count)
            }

        var comparisons: [SchedulerPrefillDecisionReport.WorkloadComparison] = []
        for workload in requiredWorkloads {
            guard let cap0 = groups[SchedulerPrefillDecisionCell(
                workload: workload,
                maxConcurrentPartialPrefills: 0
            )], let cap1 = groups[SchedulerPrefillDecisionCell(
                workload: workload,
                maxConcurrentPartialPrefills: 1
            )], !cap0.isEmpty, !cap1.isEmpty
            else { continue }

            let cap0Rows = medianTTFTByRow(cap0, rowCount: workload.rows.count)
            let cap1Rows = medianTTFTByRow(cap1, rowCount: workload.rows.count)
            let cap0Throughput = median(
                cap0.map(\.aggregatePromptTokensPerSecond))
            let cap1Throughput = median(
                cap1.map(\.aggregatePromptTokensPerSecond))
            let cap0Mean = mean(cap0Rows)
            let cap1Mean = mean(cap1Rows)

            comparisons.append(.init(
                workload: workload.name,
                cap0MedianAggregatePromptTokensPerSecond: cap0Throughput,
                cap1MedianAggregatePromptTokensPerSecond: cap1Throughput,
                throughputRatio: cap0Throughput > 0
                    ? cap1Throughput / cap0Throughput : 0,
                cap0MeanMedianTTFTMs: cap0Mean,
                cap1MeanMedianTTFTMs: cap1Mean,
                meanTTFTImprovement: cap0Mean > 0
                    ? (cap0Mean - cap1Mean) / cap0Mean : 0,
                cap0DeadlineHits: deadlineHits(
                    medians: cap0Rows, workload: workload),
                cap1DeadlineHits: deadlineHits(
                    medians: cap1Rows, workload: workload),
                cap1TTFTIsStrictStaircase: zip(
                    cap1Rows, cap1Rows.dropFirst()
                ).allSatisfy(<)))
        }

        var checks: [SchedulerPrefillDecisionReport.EvaluationCheck] = [
            .init(
                name: "matrix_complete",
                passed: matrixComplete,
                detail: matrixComplete
                    ? "\(requiredCells.count) cap/workload cells with \(iterationCount) iterations"
                    : "cap-0/cap-1 cells, row counts, or iteration ordinals are incomplete"),
        ]

        let enoughIterations = mode == .liveModel
            && iterationCount >= thresholds.minimumLiveIterations
        checks.append(.init(
            name: "minimum_live_iterations",
            passed: enoughIterations,
            detail: "\(iterationCount) observed; \(thresholds.minimumLiveIterations) required"))

        for comparison in comparisons {
            checks.append(.init(
                name: "throughput_\(comparison.workload)",
                passed: comparison.throughputRatio
                    >= thresholds.minimumThroughputRatio,
                detail: String(
                    format: "cap1/cap0 median aggregate throughput %.4f; floor %.4f",
                    comparison.throughputRatio,
                    thresholds.minimumThroughputRatio)))
        }

        for name in ["burst-4x4k", "burst-4x8k"] {
            let comparison = comparisons.first { $0.workload == name }
            checks.append(.init(
                name: "ttft_staircase_\(name)",
                passed: comparison?.cap1TTFTIsStrictStaircase == true,
                detail: "cap 1 median row TTFT must be strictly increasing"))
            checks.append(.init(
                name: "ttft_mean_improvement_\(name)",
                passed: (comparison?.meanTTFTImprovement ?? -.infinity)
                    >= thresholds.minimumBurstMeanTTFTImprovement,
                detail: String(
                    format: "mean median-row TTFT improvement %.4f; floor %.4f",
                    comparison?.meanTTFTImprovement ?? -.infinity,
                    thresholds.minimumBurstMeanTTFTImprovement)))
        }

        let eightK = comparisons.first { $0.workload == "burst-4x8k" }
        checks.append(.init(
            name: "ttft_8k_deadline_landings",
            passed: (eightK?.cap1DeadlineHits ?? 0)
                >= thresholds.minimum8KBurstDeadlineHits
                && (eightK?.cap1DeadlineHits ?? 0) > (eightK?.cap0DeadlineHits ?? 0),
            detail: "cap 1 must land at least \(thresholds.minimum8KBurstDeadlineHits) "
                + "rows and improve on cap 0 under 10,000ms + 1ms/token"))

        let mixed = requiredWorkloads.first { $0.name == "mixed-long-first" }
        let mixedCap1 = groups.first { cell, _ in
            cell.workloadName == "mixed-long-first"
                && cell.maxConcurrentPartialPrefills == 1
        }?.value
        let shortRow = mixed?.rows.enumerated().min {
            $0.element.promptTokens < $1.element.promptTokens
        }
        let shortTTFT = shortRow.flatMap { row in
            mixedCap1.map {
                medianTTFTByRow($0, rowCount: mixed?.rows.count ?? 0)[row.offset]
            }
        }
        let shortBudget = shortRow.map {
            thresholds.firstContentBaseMs
                + Double($0.element.promptTokens)
                    * thresholds.firstContentPerPromptTokenMs
        }
        let shortPromptPass: Bool
        if let shortTTFT, let shortBudget {
            shortPromptPass = shortTTFT <= shortBudget
        } else {
            shortPromptPass = false
        }
        checks.append(.init(
            name: "mixed_short_prompt_deadline",
            passed: shortPromptPass,
            detail: String(
                format: "cap 1 short-row median TTFT %.3fms; budget %.3fms",
                shortTTFT ?? .infinity,
                shortBudget ?? -.infinity)))

        let resolvedBackends = results.compactMap(\.resolvedKVBackend)
        let backendConsistent =
            resolvedBackends.count == results.count
            && Set(resolvedBackends).count == 1
            && resolvedBackends.allSatisfy { !$0.isEmpty }
        checks.append(.init(
            name: "backend_consistent",
            passed: mode != .liveModel || backendConsistent,
            detail: mode == .liveModel
                ? "\(resolvedBackends.count)/\(results.count) result backends recorded; "
                    + "\(Set(resolvedBackends).count) unique"
                : "not applicable to scheduler simulation"))

        let packingRecorded = results.allSatisfy { result in
            guard result.packedPrefill.modelAndCacheSupported != nil,
                let executed = result.packedPrefill.executed
            else { return false }
            return !result.packedPrefill.schedulerEligible || executed
        }
        checks.append(.init(
            name: "packed_prefill_execution_recorded",
            passed: mode != .liveModel || packingRecorded,
            detail: mode == .liveModel
                ? "every live cell records support and executes each scheduler-eligible cohort"
                : "not applicable to scheduler simulation"))

        let modelBound = validModelIdentity(modelIdentity)
        checks.append(.init(
            name: "model_identity",
            passed: mode != .liveModel || modelBound,
            detail: modelBound
                ? "Qwen config plus config/checkpoint SHA-256 recorded"
                : "live evidence requires validated Qwen config and checkpoint identity"))

        let reproducibilityBound = validReproducibility(reproducibility)
        checks.append(.init(
            name: "source_and_build_identity",
            passed: mode != .liveModel || reproducibilityBound,
            detail: reproducibilityBound
                ? "source, executable, build, OS, and hardware identity recorded"
                : "live evidence requires valid source and executable hashes plus "
                    + "build, OS, and hardware identity"))

        let signedIdentityBound = validSignedArtifactIdentity(
            signedArtifactIdentity,
            reproducibility: reproducibility)
        let signedEvidenceConsistent = evidenceClass == .signedCandidateModelFamily
            ? signedIdentityBound
            : signedArtifactIdentity == nil
        checks.append(.init(
            name: "signed_artifact_identity",
            passed: signedEvidenceConsistent,
            detail: evidenceClass == .signedCandidateModelFamily
                ? (signedIdentityBound
                    ? "packaged signature, registered binary hash, and version are bound"
                    : "signed evidence requires matching packaged identity metadata")
                : "unsigned and simulated evidence cannot carry signed identity metadata"))

        let postureValid = reproducibility.map { metadata in
            let start = metadata.postureAtStart
            let end = metadata.postureAtEnd
            let disallowedThermal = Set(["serious", "critical"])
            return start.powerSource == "ac"
                && end.powerSource == "ac"
                && !start.lowPowerModeEnabled
                && !end.lowPowerModeEnabled
                && !disallowedThermal.contains(start.thermalState)
                && !disallowedThermal.contains(end.thermalState)
        } ?? false
        checks.append(.init(
            name: "power_thermal_posture",
            passed: mode != .liveModel || postureValid,
            detail: mode == .liveModel
                ? "live comparison requires AC power, Low Power Mode off, and no serious thermal pressure"
                : "not applicable to scheduler simulation"))

        let prerequisitesComplete = mode == .liveModel
            && matrixComplete
            && enoughIterations
            && modelBound
            && reproducibilityBound
            && signedEvidenceConsistent
            && backendConsistent
            && packingRecorded
        let outcome: SchedulerPrefillDecisionReport.EvaluationOutcome
        if !prerequisitesComplete {
            outcome = .insufficientEvidence
        } else {
            outcome = checks.allSatisfy(\.passed) ? .pass : .fail
        }

        return .init(
            outcome: outcome,
            thresholds: thresholds,
            comparisons: comparisons,
            checks: checks,
            releaseCandidateCertified: false,
            limitation: evidenceClass == .signedCandidateModelFamily
                ? "This is signed evidence for one model family only. Global FCFS remains "
                    + "uncertified until representative non-Qwen signed matrices also pass."
                : "This unsigned local harness never certifies signed model-family evidence; "
                    + "run the packaged signed-candidate command.")
    }

    private static func medianTTFTByRow(
        _ results: [SchedulerPrefillDecisionReport.Result],
        rowCount: Int
    ) -> [Double] {
        (0 ..< rowCount).map { row in
            median(results.compactMap {
                $0.rows.first { $0.row == row }?.ttftMs
            })
        }
    }

    private static func deadlineHits(
        medians: [Double],
        workload: SchedulerPrefillDecisionReport.Workload
    ) -> Int {
        zip(medians, workload.rows).count { median, row in
            median <= thresholds.firstContentBaseMs
                + Double(row.promptTokens)
                    * thresholds.firstContentPerPromptTokenMs
        }
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func validModelIdentity(
        _ identity: SchedulerPrefillDecisionReport.ModelIdentity?
    ) -> Bool {
        guard let identity else { return false }
        return SchedulerPrefillDecisionMetadata.isReportSafeModelID(
            identity.operatorModelID)
            && identity.modelType == "qwen3_5_moe"
            && isHex(identity.configSHA256, lengths: [64])
            && isHex(identity.snapshotAggregateSHA256, lengths: [64])
    }

    private static func validReproducibility(
        _ value: SchedulerPrefillDecisionReport.Reproducibility?
    ) -> Bool {
        guard let value else { return false }
        return isHex(value.sourceSHA, lengths: [40, 64])
            && isHex(value.executableSHA256, lengths: [64])
            && !value.startedAtUTC.isEmpty
            && !value.finishedAtUTC.isEmpty
            && value.elapsedSeconds > 0
            && !value.providerVersion.isEmpty
            && !value.executableName.isEmpty
            && !value.buildConfiguration.isEmpty
            && !value.operatingSystem.isEmpty
            && !value.hardware.machineModel.isEmpty
            && !value.hardware.chipName.isEmpty
            && value.hardware.memoryGB > 0
            && value.hardware.gpuCores > 0
    }

    private static func validSignedArtifactIdentity(
        _ identity: SchedulerPrefillDecisionReport.SignedArtifactIdentity?,
        reproducibility: SchedulerPrefillDecisionReport.Reproducibility?
    ) -> Bool {
        guard let identity, let reproducibility else { return false }
        return identity.identifier == SignedReleaseIdentity.identifier
            && identity.teamID == SignedReleaseIdentity.teamID
            && identity.expectedProviderVersion == identity.observedProviderVersion
            && identity.observedProviderVersion == reproducibility.providerVersion
            && identity.expectedRegisteredBinarySHA256
                == identity.observedExecutableSHA256
            && identity.observedExecutableSHA256 == reproducibility.executableSHA256
            && isHex(identity.expectedRegisteredBinarySHA256, lengths: [64])
    }

    private static func isHex(_ value: String?, lengths: Set<Int>) -> Bool {
        guard let value, lengths.contains(value.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 70).contains(byte)
                || (97 ... 102).contains(byte)
        }
    }
}

public enum SchedulerPrefillDecisionExitStatus {
    public static func value(for report: SchedulerPrefillDecisionReport) -> Int32 {
        value(
            evidenceClass: report.evidenceClass,
            outcome: report.evaluation.outcome,
            signedIdentityPresent: report.signedArtifactIdentity != nil)
    }

    public static func value(
        evidenceClass: SchedulerPrefillDecisionReport.EvidenceClass,
        outcome: SchedulerPrefillDecisionReport.EvaluationOutcome,
        signedIdentityPresent: Bool
    ) -> Int32 {
        guard evidenceClass == .signedCandidateModelFamily,
            signedIdentityPresent
        else { return 2 }
        switch outcome {
        case .pass: return 0
        case .fail: return 1
        case .insufficientEvidence: return 2
        }
    }
}
