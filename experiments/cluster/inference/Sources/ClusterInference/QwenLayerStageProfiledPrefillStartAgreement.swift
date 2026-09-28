import Foundation

/// Construct only from verified local source metadata and admitted local token
/// history. Start packets compare to this object; they never construct it.
struct QwenLayerStageProfiledPrefillStartAgreement {
    struct Descriptor: Encodable {
        let version: Int
        let flow: String
        let profile: QwenLayerStagePrefillProfile
        let profileFingerprint: String
        let schedulingPolicy: QwenLayerStageProfiledPrefillMeasurementFlow.SchedulingPolicy
        let epoch: String
        let requestID: String
        let requestFingerprint: String
        let recordedRequestFingerprint: String
        let promptCount: Int
        let chunkSize: Int
        let outputCount: Int
        let batchSize: Int
        let frameCount: Int
        let promptTokenIDsSHA256: String
        let sourceConfigurationSHA256: String
        let artifactAggregateSHA256: String
        let storageCommitmentSHA256: String
        let planFingerprint: String
        let producerStageFingerprint: String
        let consumerStageFingerprint: String
        let producerConstructionConfigurationSHA256: String
        let consumerConstructionConfigurationSHA256: String
        let bf16ConversionEnabled: Bool
        let arithmeticEnvironmentSHA256: String
        let hiddenSize: Int
        let nativeDType: String
        let logitsDType: String
        let vocabularySize: Int
        let selectionPolicy: String
    }

    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let sourceIdentity: QwenLayerStageWireSourceIdentity
    let descriptor: Descriptor
    let fingerprint: String

    /// arithmeticEnvironmentSHA256 is SHA256(canonicalJSONData(the actual
    /// admitted QwenLongPrefillArithmeticEnvironment.Receipt)). The coordinator
    /// must obtain/bind that receipt before MLX initialization and model loading;
    /// this pure codec validates the canonical pin and peer equality only.
    init(epoch: String, request: QwenLayerStageProfiledPrefillRecordedRequest,
         sourceIdentity: QwenLayerStageWireSourceIdentity, consumerStageFingerprint: String,
         producerConstructionConfigurationSHA256: String, consumerConstructionConfigurationSHA256: String,
         bf16ConversionEnabled: Bool, arithmeticEnvironmentSHA256: String,
         hiddenSize: Int, nativeDType: String, logitsDType: String,
         schedulingPolicy: QwenLayerStageProfiledPrefillMeasurementFlow.SchedulingPolicy) throws {
        let profile = request.request.profile
        guard epoch.utf8.count == 32,
              epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              request.request.batchSize == 1, request.request.outputCount == 1, request.teacherTokenIDs.isEmpty,
              request.steps.count == request.request.prefillFrameCount,
              (1...profile.maximumPrefillFrames).contains(request.steps.count),
              request.steps.allSatisfy({ $0.frame.phase == .prefill }),
              request.steps.last?.committedTokens == request.request.promptCount,
              (1...profile.maximumHiddenSize).contains(hiddenSize),
              (1...profile.maximumVocabularySize).contains(request.vocabularySize),
              [consumerStageFingerprint, producerConstructionConfigurationSHA256, arithmeticEnvironmentSHA256,
               consumerConstructionConfigurationSHA256].allSatisfy(qwenStageWireIsSHA256) else {
            throw ProbeError("Profiled agreement requires a fresh epoch, admitted prompt and verified stage metadata")
        }
        _ = try qwenStageWireElementBytes(nativeDType)
        _ = try qwenStageWireElementBytes(logitsDType)
        let descriptor = Descriptor(version: QwenLayerStageProfiledPrefillMeasurementFlow.version,
            flow: QwenLayerStageProfiledPrefillMeasurementFlow.name,
            profile: profile, profileFingerprint: profile.fingerprint, schedulingPolicy: schedulingPolicy, epoch: epoch,
            requestID: request.request.requestID.uuidString.lowercased(), requestFingerprint: request.request.fingerprint,
            recordedRequestFingerprint: request.fingerprint, promptCount: request.request.promptCount,
            chunkSize: request.request.chunkSize, outputCount: 1, batchSize: 1, frameCount: request.steps.count,
            promptTokenIDsSHA256: sha256(Data(request.promptTokenIDs.map(String.init).joined(separator: ",").utf8)),
            sourceConfigurationSHA256: sourceIdentity.sourceConfigurationSHA256,
            artifactAggregateSHA256: sourceIdentity.artifactAggregateSHA256,
            storageCommitmentSHA256: sourceIdentity.storageCommitmentSHA256,
            planFingerprint: sourceIdentity.planFingerprint, producerStageFingerprint: sourceIdentity.producerStageFingerprint,
            consumerStageFingerprint: consumerStageFingerprint,
            producerConstructionConfigurationSHA256: producerConstructionConfigurationSHA256,
            consumerConstructionConfigurationSHA256: consumerConstructionConfigurationSHA256,
            bf16ConversionEnabled: bf16ConversionEnabled, arithmeticEnvironmentSHA256: arithmeticEnvironmentSHA256,
            hiddenSize: hiddenSize, nativeDType: nativeDType,
            logitsDType: logitsDType, vocabularySize: request.vocabularySize,
            selectionPolicy: QwenLayerStageProfiledPrefillMeasurementFlow.selectionPolicy)
        self.request = request; self.sourceIdentity = sourceIdentity; self.descriptor = descriptor
        self.fingerprint = QwenLayerStageProfiledWireHash.fingerprint(domain: QwenLayerStageProfiledWireHash.agreement,
            bytes: try canonicalJSONData(descriptor))
    }

    func boundaryExpectation(for frame: QwenLayerStageFrame) throws -> QwenLayerStageProfiledBoundaryWireExpectation {
        try .init(request: request, frame: frame, sourceIdentity: sourceIdentity,
                  hiddenSize: descriptor.hiddenSize, nativeDType: descriptor.nativeDType)
    }

    var consumerIdentity: QwenLayerStageSessionIdentity {
        .init(stageIndex: 1, requestFingerprint: descriptor.requestFingerprint,
            artifactAggregateSHA256: descriptor.artifactAggregateSHA256,
            storageCommitmentSHA256: descriptor.storageCommitmentSHA256,
            bf16ConversionEnabled: descriptor.bf16ConversionEnabled,
            sourceConfigurationSHA256: descriptor.sourceConfigurationSHA256,
            constructionConfigurationSHA256: descriptor.consumerConstructionConfigurationSHA256,
            planFingerprint: descriptor.planFingerprint, stageFingerprint: descriptor.consumerStageFingerprint,
            activationDType: descriptor.nativeDType)
    }
}

struct QwenLayerStageProfiledPrefillStartWirePacket {
    static let maximumEncodedBytes = 8 * 1024
    let agreementFingerprint: String
    private let data: Data
    var wireBytesSHA256: String { sha256(data) }
    var fingerprint: String {
        QwenLayerStageProfiledWireHash.fingerprint(domain: QwenLayerStageProfiledWireHash.start, bytes: data)
    }

    init(agreement: QwenLayerStageProfiledPrefillStartAgreement) throws {
        agreementFingerprint = agreement.fingerprint
        data = try canonicalJSONData(Content(agreement: agreement))
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Profiled start exceeds 8 KiB") }
    }

    private init(agreementFingerprint: String, data: Data) {
        self.agreementFingerprint = agreementFingerprint; self.data = data
    }

    func encoded() -> Data { data }

    static func decode(_ data: Data, expectedAgreement: QwenLayerStageProfiledPrefillStartAgreement) throws -> Self {
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        try QwenLayerStagePrefillWireJSON.requireExact(object, expected: Content(agreement: expectedAgreement))
        return Self(agreementFingerprint: expectedAgreement.fingerprint, data: data)
    }

    private struct Content: Encodable {
        let version = QwenLayerStageProfiledPrefillMeasurementFlow.version
        let flow = QwenLayerStageProfiledPrefillMeasurementFlow.name
        let kind = "start"
        let agreementFingerprint: String
        let agreement: QwenLayerStageProfiledPrefillStartAgreement.Descriptor
        init(agreement: QwenLayerStageProfiledPrefillStartAgreement) {
            agreementFingerprint = agreement.fingerprint; self.agreement = agreement.descriptor
        }
    }
}
