import Foundation

/// Retained metadata only. Actual resources, process arithmetic, model loading,
/// request permission, publication and lifetime deadlines belong to the entry.
struct QwenResidentBenchmarkWorkerAdmission {
    let options: Options
    let requests: [QwenRegistered9BLongPrefillReferenceAdmission]
    let rankRequests: [QwenLongPrefillResidentRankRequest]
    let jacclConfiguration: QwenResidentJACCLConfiguration?
}

extension QwenResidentBenchmarkWorkerCLI {
    static let maximumConfigurationBytes = 1024 * 1024
    static let maximumPromptBytes = 65_536

    /// The caller owns the bounded IO implementation. Read each input once;
    /// retained bytes, not fresh path reads, construct all four requests.
    func preflight(open: QwenResidentBenchmarkWorkerOpen,
        arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt,
        jacclConfiguration: QwenResidentJACCLConfiguration? = nil,
        read: (URL, Int) throws -> Data
    ) throws -> QwenResidentBenchmarkWorkerAdmission {
        _ = try options(open: open, jacclConfiguration: jacclConfiguration)
        let configuration = try read(modelDirectory.appendingPathComponent("config.json"),
                                     Self.maximumConfigurationBytes)
        try Self.requireBounded(configuration, maximum: Self.maximumConfigurationBytes)
        let prompt = try read(tokensFile, Self.maximumPromptBytes)
        return try admit(open: open, arithmetic: arithmetic, configuration: configuration, prompt: prompt,
                         jacclConfiguration: jacclConfiguration)
    }

    /// Pure fixture/retained-input seam, still using actual registered and
    /// resident admission constructors. No caller-created Options are accepted.
    func admit(open: QwenResidentBenchmarkWorkerOpen,
        arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt,
        configuration: Data, prompt: Data, jacclConfiguration: QwenResidentJACCLConfiguration? = nil
    ) throws -> QwenResidentBenchmarkWorkerAdmission {
        let options = try options(open: open, jacclConfiguration: jacclConfiguration)
        try Self.requireBounded(configuration, maximum: Self.maximumConfigurationBytes)
        try Self.requireBounded(prompt, maximum: Self.maximumPromptBytes)
        let requests = try open.requests.map { request in
            try QwenRegistered9BLongPrefillReferenceAdmission(configuration: configuration,
                expectedArtifactAggregateSHA256: artifactAggregateSHA256,
                promptData: prompt, expectedPromptSHA256: promptSHA256,
                request: .init(profile: .longPrefill8KV1,
                    requestID: QwenLayerStageRankAdmission.requestID(epoch: request.epoch),
                    batchSize: 1, promptCount: 8192, chunkSize: 512, outputCount: 1),
                arithmetic: arithmetic, stageCut: stageCut)
        }
        let rankRequests: [QwenLongPrefillResidentRankRequest]
        switch role {
        case .solo:
            _ = try QwenLongPrefillResidentSoloAdmission.validate(options: options,
                requests: requests, warmupCount: QwenResidentBenchmarkWorkerCommand.warmupCount)
            rankRequests = []
        case .rank:
            rankRequests = zip(open.requests, requests).map { .init(epoch: $0.0.epoch, local: $0.1) }
            try QwenLongPrefillResidentRankAdmission.validate(options: options, requests: rankRequests,
                warmupCount: QwenResidentBenchmarkWorkerCommand.warmupCount,
                jacclConfiguration: jacclConfiguration)
        }
        return .init(options: options, requests: requests, rankRequests: rankRequests,
                     jacclConfiguration: jacclConfiguration)
    }

    private static func requireBounded(_ data: Data, maximum: Int) throws {
        guard !data.isEmpty, data.count <= maximum else {
            throw ProbeError("Resident benchmark retained input is empty or exceeds its byte cap")
        }
    }
}
