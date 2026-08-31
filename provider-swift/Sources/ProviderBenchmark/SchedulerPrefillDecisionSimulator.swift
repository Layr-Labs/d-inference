import Foundation
import MLXLMCommon
import ProviderCore

extension SchedulerPrefillBenchmark {
    /// Drives the production scheduler and converts its prompt assignments to
    /// a normalized wall clock. Decode work consumes scheduler budget but zero
    /// modeled time, isolating policy from hardware execution cost.
    public static func deterministicQwenPolicyEvaluation(
        promptTokensPerSecond: Double = qwenReleaseModeledPromptTPS
    ) throws -> SchedulerPrefillDecisionReport {
        try SchedulerPrefillDecisionSimulator.report(
            promptTokensPerSecond: promptTokensPerSecond)
    }
}

enum SchedulerPrefillDecisionSimulator {
    static func report(
        promptTokensPerSecond: Double
    ) throws -> SchedulerPrefillDecisionReport {
        guard promptTokensPerSecond.isFinite, promptTokensPerSecond > 0 else {
            throw SchedulerPrefillDecisionError.invalidPromptTokensPerSecond(
                promptTokensPerSecond)
        }

        let configuration = SchedulerPrefillDecisionScenarios.configuration(
            modeledPromptTokensPerSecond: promptTokensPerSecond,
            timingBasis: "real SchedulerV2 assignments; normalized prompt clock; "
                + "decode execution time excluded")
        var results: [SchedulerPrefillDecisionReport.Result] = []
        for workload in SchedulerPrefillDecisionScenarios.qwenEvaluationWorkloads {
            for cap in SchedulerPrefillDecisionScenarios.partialPrefillCaps {
                results.append(try simulate(
                    workload,
                    maxConcurrentPartialPrefills: cap,
                    configuration: configuration,
                    promptTokensPerSecond: promptTokensPerSecond))
            }
        }
        let evaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .deterministicScheduler,
            results: results,
            modelIdentity: nil,
            reproducibility: nil)

        return SchedulerPrefillDecisionReport(
            schemaVersion: SchedulerPrefillDecisionReport.currentSchemaVersion,
            mode: .deterministicScheduler,
            evidenceClass: .schedulerSimulation,
            signedArtifactIdentity: nil,
            modelIdentity: nil,
            reproducibility: nil,
            configuration: configuration,
            kvBackend: nil,
            results: results,
            evaluation: evaluation)
    }

    private static func simulate(
        _ workload: SchedulerPrefillDecisionReport.Workload,
        maxConcurrentPartialPrefills cap: Int,
        configuration: SchedulerPrefillDecisionReport.Configuration,
        promptTokensPerSecond: Double
    ) throws -> SchedulerPrefillDecisionReport.Result {
        let scheduler = SchedulerV2(config: CBv2SchedulerConfig(
            maxConcurrentRequests: configuration.maxConcurrentRequests,
            maxBatchedTokensPerStep: configuration.maxBatchedTokensPerStep,
            prefillChunkSize: configuration.prefillChunkTokens,
            soloPrefillStripeTokens: configuration.soloPrefillStripeTokens,
            // Production resolves a non-positive operator value to nil.
            maxConcurrentPartialPrefills: cap > 0 ? cap : nil,
            maxWaiting: 64))

        let decodeID = CBv2RequestID(1_000_000)
        let activeDecodeMaxTokens = workload.activeDecode
            ? try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
                workload: workload,
                schedulerSteps: nil,
                configuration: configuration)
            : nil
        if workload.activeDecode {
            try scheduler.enqueue(CBv2Request(
                id: decodeID,
                promptTokens: [1],
                sampling: CBv2SamplingParams(temperature: 0),
                maxTokens: activeDecodeMaxTokens ?? 0,
                stopTokens: []))
            let seed = scheduler.plan()
            guard seed.assignments.contains(where: {
                $0.id == decodeID && $0.numTokens == 1
            }) else {
                throw SchedulerPrefillDecisionError.activeDecodeBootstrapFailed(
                    workload.name)
            }
            scheduler.markPendingSamples(ids: [decodeID])
            scheduler.recordSampled(id: decodeID, token: 1)
        }

        let orderedRows = workload.orderedRows
        let requestIDs = workload.rows.indices.map {
            CBv2RequestID(UInt64($0 + 1))
        }
        let rowByRequestID = Dictionary(uniqueKeysWithValues:
            requestIDs.enumerated().map { ($0.element, $0.offset) })

        var pendingIndex = 0
        var elapsedMs = 0.0
        var firstTokenAt = [Int: Double]()
        var schedulerSteps = 0
        var eligibleGroups = 0
        var eligibleRows = 0

        func enqueueReadyRows() throws {
            while pendingIndex < orderedRows.count,
                orderedRows[pendingIndex].input.arrivalMs <= elapsedMs
            {
                let ready = orderedRows[pendingIndex]
                try scheduler.enqueue(
                    CBv2Request(
                        id: requestIDs[ready.index],
                        promptTokens: Array(
                            repeating: ready.index + 2,
                            count: ready.input.promptTokens),
                        sampling: CBv2SamplingParams(temperature: 0),
                        maxTokens: 1,
                        stopTokens: []),
                    now: Date(
                        timeIntervalSinceReferenceDate:
                            ready.input.arrivalMs / 1000.0))
                pendingIndex += 1
            }
        }

        while firstTokenAt.count < workload.rows.count {
            try enqueueReadyRows()
            let hasArrivedPrompt = workload.rows.indices.contains { row in
                guard firstTokenAt[row] == nil,
                    workload.rows[row].arrivalMs <= elapsedMs,
                    let record = scheduler.record(for: requestIDs[row])
                else { return false }
                return record.numComputedTokens < workload.rows[row].promptTokens
            }
            if !hasArrivedPrompt {
                guard pendingIndex < orderedRows.count else {
                    throw SchedulerPrefillDecisionError.schedulerStalled(workload.name)
                }
                elapsedMs = max(elapsedMs, orderedRows[pendingIndex].input.arrivalMs)
                try enqueueReadyRows()
            }

            let computedBefore = Dictionary(uniqueKeysWithValues:
                requestIDs.compactMap { id -> (CBv2RequestID, Int)? in
                    scheduler.record(for: id).map { (id, $0.numComputedTokens) }
                })
            let plan = scheduler.plan()
            schedulerSteps += 1
            guard schedulerSteps <= 100_000 else {
                throw SchedulerPrefillDecisionError.schedulerStalled(workload.name)
            }

            var assignedPromptByRow = [Int: Int]()
            var cohortSizes = [Int: Int]()
            for assignment in plan.assignments {
                guard assignment.id != decodeID,
                    let row = rowByRequestID[assignment.id],
                    let before = computedBefore[assignment.id]
                else { continue }
                let remainingPrompt = max(
                    0, workload.rows[row].promptTokens - before)
                let promptAssigned = min(remainingPrompt, assignment.numTokens)
                guard promptAssigned > 0 else { continue }
                assignedPromptByRow[row] = promptAssigned
                if promptAssigned > 1 {
                    cohortSizes[promptAssigned, default: 0] += 1
                }
            }

            for count in cohortSizes.values where count > 1 {
                eligibleGroups += 1
                eligibleRows += count
            }

            let promptTokensThisStep = assignedPromptByRow.values.reduce(0, +)
            guard promptTokensThisStep > 0 else {
                throw SchedulerPrefillDecisionError.schedulerStalled(workload.name)
            }
            elapsedMs += Double(promptTokensThisStep)
                / promptTokensPerSecond * 1000.0

            if plan.assignments.contains(where: { $0.id == decodeID }) {
                scheduler.markPendingSamples(ids: [decodeID])
                scheduler.recordSampled(id: decodeID, token: 1)
                if let record = scheduler.record(for: decodeID),
                    record.generatedTokenCount >= (activeDecodeMaxTokens ?? 0)
                {
                    scheduler.finish(id: decodeID, reason: .length)
                }
            }

            for (row, assigned) in assignedPromptByRow {
                guard let before = computedBefore[requestIDs[row]],
                    before + assigned >= workload.rows[row].promptTokens
                else { continue }
                firstTokenAt[row] = elapsedMs
                let id = requestIDs[row]
                scheduler.markPendingSamples(ids: [id])
                scheduler.recordSampled(id: id, token: row + 2)
                scheduler.finish(id: id, reason: .length)
            }
        }

        if workload.activeDecode {
            guard scheduler.record(for: decodeID) != nil else {
                throw SchedulerPrefillDecisionError.activeDecodeEndedEarly(
                    workload: workload.name,
                    maxTokens: activeDecodeMaxTokens ?? 0,
                    generatedTokens: activeDecodeMaxTokens ?? 0,
                    reason: "deterministic constrained-budget sentinel reached length")
            }
            scheduler.finish(id: decodeID, reason: .cancelled)
        }

        let rows = try workload.rows.indices.map {
            row -> SchedulerPrefillDecisionReport.Row in
            guard let first = firstTokenAt[row] else {
                throw SchedulerPrefillDecisionError.missingFirstToken(
                    workload: workload.name, row: row)
            }
            let arrival = workload.rows[row].arrivalMs
            return SchedulerPrefillDecisionReport.Row(
                row: row,
                promptTokens: workload.rows[row].promptTokens,
                scheduledArrivalMs: arrival,
                submittedAtMs: arrival,
                firstTokenAtMs: first,
                ttftMs: first - arrival)
        }
        let firstArrival = workload.rows.map(\.arrivalMs).min() ?? 0
        let lastFirstToken = rows.map(\.firstTokenAtMs).max() ?? firstArrival
        let makespanMs = max(0, lastFirstToken - firstArrival)

        return SchedulerPrefillDecisionReport.Result(
            workload: workload,
            iteration: 1,
            maxConcurrentPartialPrefills: cap,
            rows: rows,
            totalPromptTokens: workload.totalPromptTokens,
            makespanMs: makespanMs,
            aggregatePromptTokensPerSecond: makespanMs > 0
                ? Double(workload.totalPromptTokens) / (makespanMs / 1000.0)
                : 0,
            schedulerSteps: schedulerSteps,
            packedPrefill: .init(
                schedulerEligible: eligibleGroups > 0,
                modelAndCacheSupported: nil,
                executed: nil,
                eligibleGroups: eligibleGroups,
                eligibleRows: eligibleRows,
                executedGroups: nil,
                executedRows: nil),
            resolvedKVBackend: nil)
    }
}
