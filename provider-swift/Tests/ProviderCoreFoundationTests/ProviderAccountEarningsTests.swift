import Foundation
import Testing
@testable import ProviderCoreFoundation

@Test("provider account earnings round-trip RFC3339 and tolerate omitted optional arrays")
func providerAccountEarningsWireContract() throws {
    let json = """
    {
      "account_id": "acct-1",
      "earnings": [{
        "id": 1,
        "account_id": "acct-1",
        "provider_id": "session-1",
        "provider_key": "key-1",
        "job_id": "job-1",
        "model": "model-1",
        "amount_micro_usd": 42,
        "prompt_tokens": 10,
        "completion_tokens": 5,
        "created_at": "2026-08-24T09:30:00.123456789Z"
      }],
      "total_micro_usd": 42,
      "total_usd": "0.000042",
      "count": 1,
      "available_balance_micro_usd": 42,
      "available_balance_usd": "0.000042",
      "withdrawable_balance_micro_usd": 40,
      "withdrawable_balance_usd": "0.000040"
    }
    """

    let decoded = try JSONDecoder().decode(
        ProviderAccountEarningsReport.self,
        from: Data(json.utf8)
    )
    #expect(decoded.accountID == "acct-1")
    #expect(decoded.providers == [])
    #expect(decoded.recentCount == 1)
    #expect(decoded.historyLimit == 1)
    #expect(decoded.earnings[0].createdAt != nil)

    let encoded = try JSONEncoder().encode(decoded)
    let raw = String(decoding: encoded, as: UTF8.self)
    #expect(raw.contains("\"created_at\":\"2026-08-24T09:30:00"))
    #expect(!raw.contains("\"created_at\":1."))
    #expect(
        try JSONDecoder().decode(
            ProviderAccountEarningsReport.self,
            from: encoded
        ) == decoded
    )
}

@Test("provider machine identity matches the coordinator wire contract")
func providerMachineIdentityContract() {
    #expect(
        ProviderMachineIdentity.id(serialNumber: "SERIAL-9")
            == "63ecd36d8a4ecfab1b8ca32e884921afc9bf303a079cefb06362a6c4c2219ac0"
    )
    #expect(ProviderMachineIdentity.id(serialNumber: "") == nil)
}
