import Testing

@testable import ProviderCore

@Suite("SSD prefix-cache diagnosis")
struct PrefixCacheDiagnosisTests {
    private func status(
        _ state: PrefixCacheStatusState, _ reason: PrefixCacheStatusReason,
        _ detail: SSDPrefixCacheConstructionFailure? = nil
    ) -> PrefixCacheModelStatus {
        .init(modelId: "m", backend: .paged, replayStrategy: .unknown, state: state, reason: reason, detail: detail)
    }

    @Test("the load notice names the model, the cause status prints, and the fix")
    func loadNoticeCarriesCauseAndFix() throws {
        let notice = try #require(PrefixCacheDiagnosis.loadNotice(
            status(.error, .diskUnavailable, .unsafePath), cliName: "darkbloom"))
        #expect(notice.hasPrefix(
            "SSD prefix cache unavailable for m (disk_unavailable: unsafe_path); "
                + "serving uncached until the model reloads. Fix: check `darkbloom cache status`"))
        let slot = DaemonState.SlotPosture(model: "m", prefixCache: status(.error, .diskUnavailable, .unsafePath))
        #expect(PrefixCacheDiagnosis.statusPhrase(slot) == "prefix_cache=FAILED (disk_unavailable: unsafe_path)")

        // A cause with no operator fix, such as a scan failure, gets no fix.
        #expect(PrefixCacheDiagnosis.loadNotice(status(.error, .scanFailed), cliName: "darkbloom")
            == "SSD prefix cache unavailable for m (scan_failed); serving uncached until the model reloads.")
        #expect(PrefixCacheDiagnosis.loadNotice(status(.ready, .ready)) == nil)
        #expect(PrefixCacheDiagnosis.loadNotice(status(.disabled, .configDisabled)) == nil)
    }
}
