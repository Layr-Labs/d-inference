import FanControlIPC
import Testing

@Suite("Fan helper IPC contract")
struct FanControlIPCTests {
    @Test("peer requirements pin identifiers and developer team")
    func signingRequirements() {
        #expect(
            FanControlIPC.clientRequirement.contains(
                "identifier \"io.darkbloom.provider\""
            )
        )
        #expect(
            FanControlIPC.helperRequirement.contains(
                "identifier \"io.darkbloom.provider.fan-helper\""
            )
        )
        #expect(
            FanControlIPC.clientRequirement.contains(
                "certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
            )
        )
    }

    @Test("lease protocol version is pinned")
    func protocolVersion() {
        #expect(FanControlIPC.protocolVersion == 1)
    }
}
