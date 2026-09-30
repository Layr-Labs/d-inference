import XCTest
@testable import ProviderCore

final class MiMoV26PrefillProfileTests: XCTestCase {
    func testDefaultAndExplicitAttentionRollback() {
        XCTAssertTrue(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [:]))
        XCTAssertTrue(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [
            "DARKBLOOM_MIMO_V26_NAX_ATTENTION": "1",
            "DARKBLOOM_MIMO_BLOCK_BATCH_PREFILL": "1"]))
        for key in ["DARKBLOOM_MIMO_V26_NAX_ATTENTION", "DARKBLOOM_MIMO_BLOCK_BATCH_PREFILL"] {
            XCTAssertFalse(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [key: "0"]))
        }
    }

    func testExplicitStripeAndQueryBlockRemainAuthoritative() {
        for value in ["0", "512", "2048", "4096", "8192", "bad"] {
            XCTAssertFalse(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [
                "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": value]))
        }
        XCTAssertTrue(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [
            "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128"]))
        for value in ["0", "64", "256", "bad"] {
            XCTAssertFalse(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [
                "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": value]))
        }
    }
}
