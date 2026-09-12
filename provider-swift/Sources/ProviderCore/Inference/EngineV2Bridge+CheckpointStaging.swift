import MLXLMCommon

extension EngineV2Bridge {
    /// Refund optional staging before retrying admission as a cold request.
    func abandonPrefixStaging(requestID: CBv2RequestID) async {
        await ssdPrefixCache?.abandonStaging(requestID: requestID)
        await ssdHybridCheckpointStore?.abandonStaging(requestID: requestID)
    }

    func discardPrefixReadyReceipt(requestID: CBv2RequestID) {
        ssdPrefixCache?.discardReadyReceipt(requestID: requestID)
        ssdHybridCheckpointStore?.discardReadyReceipt(requestID: requestID)
    }
}
