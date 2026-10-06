import ArgumentParser
import Testing
@testable import darkbloom

@Suite struct EnrollCommandTests {
    @Test func helpExplainsNewProviderAndLegacyEligibility() {
        let help = Enroll.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("New providers require macOS 27 or later"))
        #expect(help.contains("coordinator-qualified App Attest"))
        #expect(help.contains("OS version alone does not establish eligibility"))
        #expect(help.contains("grandfathered account/key pairs"))
        #expect(help.contains("MDM-only providers receive no base rewards"))
        #expect(help.contains("current qualified App Attest authorization"))
        #expect(help.contains("darkbloom status"))
    }

    @Test func enrollmentOutputDoesNotPromiseQualification() {
        let notice = Enroll.eligibilityNotice
        #expect(notice.contains("New providers require macOS 27 or later"))
        #expect(notice.contains("darkbloom status"))
        #expect(notice.contains("OS version alone is not approval"))
        #expect(notice.contains("may serve temporarily"))
        #expect(notice.contains("MDM-only providers receive no base rewards"))
        #expect(notice.contains("Base rewards require current qualified App Attest authorization"))
    }
}
