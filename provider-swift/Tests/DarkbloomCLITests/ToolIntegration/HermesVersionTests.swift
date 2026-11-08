import Foundation
import Testing

@testable import darkbloom

@Suite("Hermes version")
struct HermesVersionTests {
    @Test("the version on hermes --version's first line: semantic, else its release date")
    func parsesTheVersion() {
        #expect(HermesVersion.parse("Hermes Agent v0.23.0+12 (2026.9.24)\nPython: 3.12.4") == [0, 23, 0])
        #expect(HermesVersion.parse("Hermes Agent v0.20.2 (2026.8.16)") == [0, 20, 2])
        #expect(HermesVersion.parse("Hermes Agent vgit.abc1234 (2026.8.13)") == [2026, 8, 13])
        #expect(HermesVersion.parse("Hermes Agent v2026.8.13") == [2026, 8, 13])
        #expect(HermesVersion.parse("Hermes Agent vgit.abc1234\nPython: 3.12.4") == nil)
        #expect(HermesVersion.parse("") == nil)
    }

    @Test("key_cmd came in Hermes v0.20.2 (tag v2026.8.16): an older one gets one warning line, others none")
    func keyCommandWarning() {
        let old = HermesVersion.keyCommandWarning(versionOutput: "Hermes Agent v0.20.1 (2026.8.13)")
        #expect(old == """
            Hermes v0.20.1 is older than v0.20.2 and can't read Darkbloom's key (`key_cmd`), so Darkbloom will \
            refuse its requests; update it with `hermes update`.
            """)
        #expect(HermesVersion.keyCommandWarning(versionOutput: "Hermes Agent vgit.abc1234 (2026.8.13)") != nil)
        for current in ["Hermes Agent v0.20.2 (2026.8.16)", "Hermes Agent v0.23.0+12 (2026.9.24)", "Hermes Agent v1.0.0",
                        "v2026.8.16", "Hermes Agent vgit.abc1234", ""] {
            #expect(HermesVersion.keyCommandWarning(versionOutput: current) == nil, "\(current)")
        }
    }
}
