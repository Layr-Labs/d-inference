import Foundation

enum QwenMTPAcceptedPolicy {
    case registered9BDepth1Short
    var fingerprint: String {
        sha256(Data("registered-qwen35-9b-mtp-depth1-short-v1|cut4|serial|P1-32|C1-16|O2-8|emptyStops|target-prefix-receipts|assistant-finalize|plain-lab".utf8))
    }
    func require(request: QwenLayerStageGenerationRequest, prefillPolicy: QwenResidentPrefillPolicy) throws {
        guard prefillPolicy == .serial, request.profile.hiddenSize == 4096,
              request.profile.vocabularySize == 248320, request.profile.activationDType == "bfloat16",
              (1...32).contains(request.promptCount), (1...16).contains(request.chunkSize),
              (2...8).contains(request.outputCount), request.stopTokenIDs.isEmpty else {
            throw ProbeError("MTP policy is outside the explicit short registered9B experiment")
        }
    }
}

