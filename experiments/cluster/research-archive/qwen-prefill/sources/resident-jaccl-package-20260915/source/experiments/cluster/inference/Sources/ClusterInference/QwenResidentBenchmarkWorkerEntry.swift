import Darwin
import Foundation
import MLX

extension QwenResidentBenchmarkWorkerCLI {
    func run() throws {
        // One fixed deadline covers stdin, initialization, all requests and exit.
        // It is never extended by commands. The parent independently fences all
        // ranks if a native collective, destructor or output write blocks.
        alarm(UInt32(timeoutSeconds)); defer { alarm(0) }
        let previousSIGPIPE = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previousSIGPIPE) }
        let start = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(timeoutSeconds) * 1_000_000_000
        func checked() throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= start, now - start < limit else { throw ProbeError("Resident benchmark cohort exceeded its deadline") }
        }
        let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
        let reader = WorkerLineReader()
        guard let line = try reader.next(),
              case .open(let open) = try QwenResidentBenchmarkWorkerCommand.decode(line) else {
            throw ProbeError("Resident benchmark requires its exact opening command before loading")
        }
        try checked()
        let jacclConfiguration = try admitTransport(environment: ProcessInfo.processInfo.environment,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let admission = try preflight(open: open, arithmetic: arithmetic,
            jacclConfiguration: jacclConfiguration,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let steps = admission.requests.enumerated().map { ordinal, request in
            QwenLongPrefillResidentRequestStep(ordinal: ordinal, excludedWarmup: ordinal == 0,
                requestID: request.request.request.requestID,
                recordedRequestFingerprint: request.request.fingerprint, promptFileSHA256: request.promptFileSHA256)
        }
        let output = QwenResidentBenchmarkWorkerOutput(write: { try FileHandle.standardOutput.write(contentsOf: $0) })
        let control = try QwenResidentBenchmarkWorkerControl(open: open, steps: steps, role: role.rawValue,
            read: { try reader.next() }, output: output, check: checked)
        let initialResources = try QwenResidentBenchmarkWorkerResources.require()
        try checked()
        var beforeResources: QwenResidentBenchmarkWorkerResources?
        func beforeRequest(_ step: QwenLongPrefillResidentRequestStep) throws {
            try control.permit(step)
            beforeResources = try .require()
            try checked()
        }
        func result<T: Encodable>(_ step: QwenLongPrefillResidentRequestStep, _ execution: T) throws {
            guard let before = beforeResources else { throw ProbeError("Resident result lost its pre-request resource observation") }
            let after = try QwenResidentBenchmarkWorkerResources.require()
            try control.result(step) { command in
                QwenResidentBenchmarkWorkerResultRecord(command: command, step: step, execution: execution,
                    resourcesBeforeRequest: before, resourcesAfterRequest: after)
            }
            beforeResources = nil
        }
        do {
            // No MLX initialization or model read before typed and actual gates.
            _ = MLXArray(0)
            let memory: [QwenStageMemoryObservation]
            if role == .solo {
                let report = try runQwenLongPrefillResidentSoloCohort(options: admission.options,
                    requests: admission.requests, warmupCount: 1,
                    onModelReady: { ready in
                        try control.modelReady(QwenResidentBenchmarkWorkerReadyRecord(execution: ready,
                            initialResources: initialResources, loadedResources: .require(),
                            runtime: .init()), rank: nil)
                    }, beforeRequest: beforeRequest, onRequestResult: result, check: checked)
                memory = report.memory
            } else {
                let report = try runQwenLongPrefillResidentRankCohort(options: admission.options,
                    requests: admission.rankRequests, warmupCount: 1,
                    jacclConfiguration: admission.jacclConfiguration,
                    onModelReady: { ready in
                        try control.modelReady(QwenResidentBenchmarkWorkerReadyRecord(execution: ready,
                            initialResources: initialResources, loadedResources: .require(),
                            runtime: .init()), rank: ready.rank)
                    }, beforeRequest: beforeRequest, onRequestResult: result, check: checked)
                memory = report.memory
            }
            try checked()
            try control.modelReleased(QwenResidentBenchmarkWorkerReleasedRecord(completedRequestCount: 4,
                memory: memory, resourcesAfterRelease: .require()))
            try control.shutdown(QwenResidentBenchmarkWorkerStoppedRecord())
            try checked()
        } catch { control.fail(); throw error }
    }
}
