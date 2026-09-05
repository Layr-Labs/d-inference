import Foundation
import MLXLMCommon
import ProviderCore

struct SchedulerPrefillDecisionEngineParts: Sendable {
    let engine: any CBv2Engine
    let resolvedBackend: String
}

struct SchedulerPrefillDecisionLiveMeasurement: Sendable {
    let rows: [SchedulerPrefillDecisionReport.Row]
    let makespanMs: Double
    let aggregatePromptTokensPerSecond: Double
    let packedActivity: CBv2PackedPrefillActivity
}

private actor SchedulerPrefillDecisionActiveDecodeMonitor {
    struct Snapshot: Sendable {
        let generatedTokens: Int
        let terminalReason: String?
    }

    private var generatedTokens = 0
    private var terminalReason: String?

    func record(tokens: [Int]) {
        generatedTokens += tokens.count
    }

    func recordTerminal(_ reason: String) {
        terminalReason = reason
    }

    func snapshot() -> Snapshot {
        Snapshot(
            generatedTokens: generatedTokens,
            terminalReason: terminalReason)
    }
}

enum SchedulerPrefillDecisionLiveRunner {
    private struct SubmittedRow: Sendable {
        let row: Int
        let input: SchedulerPrefillDecisionReport.WorkloadRow
        let submittedAt: UInt64
        let stream: AsyncStream<CBv2Event>
    }

    private enum ActiveDecodeStartup: Sendable {
        case ready(
            rows: [SubmittedRow],
            scenarioStartedAt: UInt64,
            generatedTokens: Int)
        case failed(String)
    }

    static func makeEngine(
        container: ModelContainer,
        isVLM: Bool,
        modelDirectory: URL,
        weightBytes: Int,
        configuration: SchedulerPrefillDecisionReport.Configuration,
        cap: Int,
        kvBackend: EngineV2KVBackendSelection
    ) async throws -> SchedulerPrefillDecisionEngineParts {
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, weightBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        var configuredEnvironment = ProcessInfo.processInfo.environment
        configuredEnvironment[EngineV2Factory.maxPartialPrefillsKey] = String(cap)
        configuredEnvironment[EngineV2Factory.soloPrefillStripeKey] =
            String(configuration.soloPrefillStripeTokens)
        let environment = configuredEnvironment

        return try await container.perform {
            context -> SchedulerPrefillDecisionEngineParts in
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: context.model,
                isVLM: isVLM,
                modelDirectory: modelDirectory)
            let build = try EngineV2Factory.makeProductionBuild(
                model: servingModel,
                tokenizer: context.tokenizer,
                modelDirectory: modelDirectory,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: configuration.maxConcurrentRequests,
                kvBackend: kvBackend,
                environment: environment)
            return SchedulerPrefillDecisionEngineParts(
                engine: build.engine,
                resolvedBackend: build.resolvedKVBackendDescriptor)
        }
    }

    static func measure(
        engine: any CBv2Engine,
        workload: SchedulerPrefillDecisionReport.Workload,
        baseTokens: [Int],
        requestIDBase: UInt64,
        activeDecodeMaxTokens: Int? = nil,
        activeDecodeProgressTimeout: Duration = .seconds(5)
    ) async throws -> SchedulerPrefillDecisionLiveMeasurement {
        let prompts = workload.rows.enumerated().map { row, input in
            ThroughputSweep.tile(
                baseTokens,
                to: input.promptTokens,
                offset: row * 17 + 1)
        }
        let decodeID = CBv2RequestID(requestIDBase + 90)
        var decodeTask: Task<Void, Never>?
        let decodeMonitor = SchedulerPrefillDecisionActiveDecodeMonitor()
        let packedBefore = engine.packedPrefillActivity()
        var bootstrapRows: [SubmittedRow] = []
        var bootstrapScenarioStartedAt: UInt64?
        var bootstrapGeneratedTokens = 0

        if workload.activeDecode {
            guard let activeDecodeMaxTokens, activeDecodeMaxTokens > 1 else {
                throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                    workload: workload.name,
                    reason: "runner received no usable token budget")
            }
            let capacity = engine.capacity()
            let stream: AsyncStream<CBv2Event>
            do {
                stream = try engine.submit(CBv2Request(
                    id: decodeID,
                    promptTokens: ThroughputSweep.tile(baseTokens, to: 16),
                    sampling: CBv2SamplingParams(temperature: 0),
                    maxTokens: activeDecodeMaxTokens,
                    stopTokens: []))
            } catch let error as CBv2KVError {
                throw SchedulerPrefillDecisionError.activeDecodeCapacityInsufficient(
                    workload: workload.name,
                    maxTokens: activeDecodeMaxTokens,
                    kvBytesCapacity: capacity.kvBytesCapacity,
                    kvBytesReserved: capacity.kvBytesReserved,
                    reason: String(describing: error))
            }
            let (startup, continuation) =
                AsyncStream<ActiveDecodeStartup>.makeStream(
                    bufferingPolicy: .bufferingNewest(1))
            decodeTask = Task {
                var signaled = false
                for await event in stream {
                    switch event {
                    case .delta(_, let tokens, _):
                        await decodeMonitor.record(tokens: tokens)
                        if !signaled, !tokens.isEmpty {
                            signaled = true
                            do {
                                let scenarioStartedAt =
                                    DispatchTime.now().uptimeNanoseconds
                                let rows = try workload.orderedRows.map { ready in
                                    let submittedAt =
                                        DispatchTime.now().uptimeNanoseconds
                                    let rowStream = try engine.submit(CBv2Request(
                                        id: CBv2RequestID(
                                            requestIDBase + UInt64(ready.index)),
                                        promptTokens: prompts[ready.index],
                                        sampling: CBv2SamplingParams(temperature: 0),
                                        maxTokens: 1,
                                        stopTokens: []))
                                    return SubmittedRow(
                                        row: ready.index,
                                        input: ready.input,
                                        submittedAt: submittedAt,
                                        stream: rowStream)
                                }
                                let generatedTokens =
                                    await decodeMonitor.snapshot().generatedTokens
                                continuation.yield(.ready(
                                    rows: rows,
                                    scenarioStartedAt: scenarioStartedAt,
                                    generatedTokens: generatedTokens))
                            } catch {
                                continuation.yield(.failed(
                                    "could not join measurement rows to resident decode: "
                                        + String(describing: error)))
                            }
                            continuation.finish()
                        }
                    case .finished(let reason, _):
                        await decodeMonitor.recordTerminal(String(describing: reason))
                        if !signaled {
                            signaled = true
                            continuation.yield(.failed(String(describing: reason)))
                            continuation.finish()
                        }
                    }
                }
                if !signaled {
                    await decodeMonitor.recordTerminal(
                        "stream ended before first token")
                    continuation.yield(.failed("stream ended before first token"))
                    continuation.finish()
                }
            }

            var startupResult: ActiveDecodeStartup?
            for await result in startup {
                startupResult = result
                break
            }
            switch startupResult {
            case .ready(let rows, let scenarioStartedAt, let generatedTokens):
                bootstrapRows = rows
                bootstrapScenarioStartedAt = scenarioStartedAt
                bootstrapGeneratedTokens = generatedTokens
            case .failed(let reason):
                engine.cancel(decodeID)
                await decodeTask?.value
                throw SchedulerPrefillDecisionError.activeDecodeFailed(
                    workload: workload.name,
                    reason: reason)
            case nil:
                engine.cancel(decodeID)
                await decodeTask?.value
                throw SchedulerPrefillDecisionError.activeDecodeFailed(
                    workload: workload.name,
                    reason: "startup signal ended without a result")
            }
        }

        let clock = SuspendingClock()
        let scenarioStart = clock.now
        let scenarioStartedAt = bootstrapScenarioStartedAt
            ?? DispatchTime.now().uptimeNanoseconds
        let bootstrapRowsByIndex = Dictionary(
            uniqueKeysWithValues: bootstrapRows.map { ($0.row, $0) })

        let measuredRows: [SchedulerPrefillDecisionReport.Row]
        do {
            measuredRows = try await withThrowingTaskGroup(
                of: SchedulerPrefillDecisionReport.Row.self
            ) { group in
                for ready in workload.orderedRows {
                    if let submitted = bootstrapRowsByIndex[ready.index] {
                        group.addTask {
                            try await measureRow(
                                stream: submitted.stream,
                                workloadName: workload.name,
                                row: submitted.row,
                                input: submitted.input,
                                submittedAt: submitted.submittedAt,
                                scenarioStartedAt: scenarioStartedAt)
                        }
                        continue
                    }
                    if ready.input.arrivalMs > 0 {
                        let deadline = scenarioStart.advanced(
                            by: .milliseconds(ready.input.arrivalMs))
                        if clock.now < deadline {
                            try await Task.sleep(
                                until: deadline,
                                tolerance: .zero,
                                clock: clock)
                        }
                    }
                    // Keep submit order deterministic for mixed long-first.
                    let row = ready.index
                    let input = ready.input
                    let submittedAt = DispatchTime.now().uptimeNanoseconds
                    let stream = try engine.submit(CBv2Request(
                        id: CBv2RequestID(requestIDBase + UInt64(row)),
                        promptTokens: prompts[row],
                        sampling: CBv2SamplingParams(temperature: 0),
                        maxTokens: 1,
                        stopTokens: []))
                    group.addTask {
                        try await measureRow(
                            stream: stream,
                            workloadName: workload.name,
                            row: row,
                            input: input,
                            submittedAt: submittedAt,
                            scenarioStartedAt: scenarioStartedAt)
                    }
                }

                var rows: [SchedulerPrefillDecisionReport.Row] = []
                for try await row in group {
                    rows.append(row)
                }
                return rows.sorted { $0.row < $1.row }
            }
        } catch {
            await stopActiveDecode(
                engine: engine,
                decodeID: decodeID,
                task: decodeTask,
                active: workload.activeDecode)
            throw error
        }

        if workload.activeDecode {
            let snapshot = await awaitActiveDecodeProgress(
                monitor: decodeMonitor,
                beyond: bootstrapGeneratedTokens,
                timeout: activeDecodeProgressTimeout)
            let failureReason: String?
            if let terminalReason = snapshot.terminalReason {
                failureReason = terminalReason
            } else if snapshot.generatedTokens <= bootstrapGeneratedTokens {
                failureReason = "sentinel made no decode progress after measurement rows joined"
            } else {
                failureReason = nil
            }
            if let failureReason {
                await stopActiveDecode(
                    engine: engine,
                    decodeID: decodeID,
                    task: decodeTask,
                    active: true)
                throw SchedulerPrefillDecisionError.activeDecodeEndedEarly(
                    workload: workload.name,
                    maxTokens: activeDecodeMaxTokens ?? 0,
                    generatedTokens: snapshot.generatedTokens,
                    reason: failureReason)
            }
            engine.cancel(decodeID)
            let terminal = await awaitActiveDecodeTerminal(
                monitor: decodeMonitor,
                timeout: activeDecodeProgressTimeout)
            decodeTask?.cancel()
            await decodeTask?.value
            guard terminal.terminalReason == String(describing: CBv2FinishReason.cancelled)
            else {
                throw SchedulerPrefillDecisionError.activeDecodeEndedEarly(
                    workload: workload.name,
                    maxTokens: activeDecodeMaxTokens ?? 0,
                    generatedTokens: terminal.generatedTokens,
                    reason: terminal.terminalReason.map {
                        "sentinel terminated as \($0), not cancellation"
                    } ?? "sentinel cancellation produced no terminal event")
            }
        }
        let packedAfter = engine.packedPrefillActivity()
        let packedActivity = CBv2PackedPrefillActivity(
            isSupported: packedAfter.isSupported,
            rowsExecuted: max(
                0, packedAfter.rowsExecuted - packedBefore.rowsExecuted),
            groupsExecuted: max(
                0, packedAfter.groupsExecuted - packedBefore.groupsExecuted))
        let firstArrival = workload.rows.map(\.arrivalMs).min() ?? 0
        let lastFirstToken = measuredRows.map(\.firstTokenAtMs).max() ?? firstArrival
        let makespanMs = max(0, lastFirstToken - firstArrival)

        return SchedulerPrefillDecisionLiveMeasurement(
            rows: measuredRows,
            makespanMs: makespanMs,
            aggregatePromptTokensPerSecond: makespanMs > 0
                ? Double(workload.totalPromptTokens) / (makespanMs / 1000.0)
                : 0,
            packedActivity: packedActivity)
    }

    private static func measureRow(
        stream: AsyncStream<CBv2Event>,
        workloadName: String,
        row: Int,
        input: SchedulerPrefillDecisionReport.WorkloadRow,
        submittedAt: UInt64,
        scenarioStartedAt: UInt64
    ) async throws -> SchedulerPrefillDecisionReport.Row {
        var firstTokenAt: UInt64?
        var finishReason: CBv2FinishReason?
        for await event in stream {
            switch event {
            case .delta(_, let tokens, _):
                if firstTokenAt == nil, !tokens.isEmpty {
                    firstTokenAt = DispatchTime.now().uptimeNanoseconds
                }
            case .finished(let reason, _):
                finishReason = reason
            }
        }
        guard let firstTokenAt else {
            if let finishReason {
                throw SchedulerPrefillDecisionError.liveRowFailed(
                    workload: workloadName,
                    row: row,
                    reason: String(describing: finishReason))
            }
            throw SchedulerPrefillDecisionError.liveRowProducedNoToken(
                workload: workloadName,
                row: row)
        }
        guard finishReason == .length else {
            throw SchedulerPrefillDecisionError.liveRowFailed(
                workload: workloadName,
                row: row,
                reason: String(describing: finishReason))
        }

        let submittedAtMs = Double(
            submittedAt - scenarioStartedAt) / 1_000_000.0
        let firstTokenAtMs = Double(
            firstTokenAt - scenarioStartedAt) / 1_000_000.0
        return SchedulerPrefillDecisionReport.Row(
            row: row,
            promptTokens: input.promptTokens,
            scheduledArrivalMs: input.arrivalMs,
            submittedAtMs: submittedAtMs,
            firstTokenAtMs: firstTokenAtMs,
            ttftMs: Double(firstTokenAt - submittedAt) / 1_000_000.0)
    }

    private static func stopActiveDecode(
        engine: any CBv2Engine,
        decodeID: CBv2RequestID,
        task: Task<Void, Never>?,
        active: Bool
    ) async {
        guard active else { return }
        engine.cancel(decodeID)
        task?.cancel()
        await task?.value
    }

    private static func awaitActiveDecodeProgress(
        monitor: SchedulerPrefillDecisionActiveDecodeMonitor,
        beyond baseline: Int,
        timeout: Duration
    ) async -> SchedulerPrefillDecisionActiveDecodeMonitor.Snapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let snapshot = await monitor.snapshot()
            if snapshot.terminalReason != nil
                || snapshot.generatedTokens > baseline
                || clock.now >= deadline
            {
                return snapshot
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func awaitActiveDecodeTerminal(
        monitor: SchedulerPrefillDecisionActiveDecodeMonitor,
        timeout: Duration
    ) async -> SchedulerPrefillDecisionActiveDecodeMonitor.Snapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let snapshot = await monitor.snapshot()
            if snapshot.terminalReason != nil || clock.now >= deadline {
                return snapshot
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
