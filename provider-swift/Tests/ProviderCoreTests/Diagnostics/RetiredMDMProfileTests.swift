import Foundation
import Testing
@testable import ProviderCore

@Suite struct RetiredMDMProfileTests {
    private let ours = MDMEnrollmentState.enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect")

    @Test func thisInstallsProfileGetsOneRemovalLine() throws {
        let cli = BuildEnvironment.current.cliName
        let notice = try #require(RetiredMDMProfile.notice(for: ours))
        #expect(!notice.contains("\n"))
        #expect(notice.contains("no longer used"))
        #expect(notice.contains("App Attest"))
        #expect(notice.contains("`\(cli) unenroll` and choose 2"))
        let diagnostic = try #require(RetiredMDMProfile.diagnostic(for: ours))
        #expect(diagnostic.level == .info)
        #expect(diagnostic.section == .trust)
        #expect(diagnostic.fix?.contains("`\(cli) unenroll` and choose 2") == true)
        #expect(diagnostic.fix?.contains("employer") == true)
    }

    @Test func noOtherProfileStateIsEverOfferedForRemoval() {
        let others: [MDMEnrollmentState] = [
            .notEnrolled, .checkFailed,
            .enrolledOtherMDM(serverURL: "https://corp.example/mdm/connect"),
            .enrolledOtherMDM(serverURL: "https://api.dev.darkbloom.xyz/mdm/connect"),
        ]
        for state in others {
            #expect(RetiredMDMProfile.notice(for: state) == nil, "\(state)")
            #expect(RetiredMDMProfile.diagnostic(for: state) == nil, "\(state)")
        }
    }
}
