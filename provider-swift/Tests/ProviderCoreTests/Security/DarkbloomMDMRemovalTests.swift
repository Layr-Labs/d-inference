import Foundation
import Testing
@testable import ProviderCore

@Suite struct DarkbloomMDMRemovalTests {
    private let coordinator = "wss://api.darkbloom.dev/ws/provider"

    private func profile(identifier: String = "io.darkbloom.enroll",
                         payloadIdentifier: String = "io.darkbloom.enroll.mdm",
                         server: String = "https://api.darkbloom.dev/mdm/connect") -> [String: Any] {
        ["ProfileIdentifier": identifier, "ProfileDisplayName": "Darkbloom Provider Enrollment",
         "ProfileItems": [["PayloadIdentifier": payloadIdentifier,
                           "PayloadType": "com.apple.mdm", "PayloadContent": ["ServerURL": server]]]]
    }

    private func target(_ profiles: [[String: Any]]) throws -> DarkbloomMDMRemovalTarget? {
        let data = try PropertyListSerialization.data(fromPropertyList: ["_computerlevel": profiles],
                                                       format: .xml, options: 0)
        return DarkbloomMDMRemoval.target(in: data, coordinatorURL: coordinator)
    }

    @Test func exactEnrollmentIsSelectedAndCompanyProfilePreserved() throws {
        let selected = try #require(try target([
            profile(), profile(identifier: "com.company.management", server: "https://corp.example/mdm/connect")]))
        #expect(selected.identifier == "io.darkbloom.enroll")
        #expect(selected.serverURL == "https://api.darkbloom.dev/mdm/connect")
    }

    @Test func namesAndDomainsCannotSelectAnEmployerProfile() throws {
        #expect(try target([profile(identifier: "com.company.management")]) == nil)
        #expect(try target([profile(payloadIdentifier: "com.company.management.mdm")]) == nil)
        #expect(try target([profile(server: "https://other.darkbloom.dev/mdm/connect")]) == nil)
        #expect(try target([profile(server: "https://api.darkbloom.dev.evil.example/mdm/connect")]) == nil)
        #expect(try target([profile(server: "https://api.darkbloom.dev:8443/mdm/connect")]) == nil)
        #expect(try target([profile(server: "http://api.darkbloom.dev/mdm/connect")]) == nil)
        #expect(try target([profile(server: "https://api.darkbloom.dev/other")]) == nil)
        #expect(try target([profile(server: "https://api.darkbloom.dev/mdm/connect?other=true")]) == nil)
    }

    @Test func ambiguousAndUnrelatedProfilesAreRefused() throws {
        #expect(try target([profile(), profile()]) == nil)
        #expect(try target([]) == nil)
        #expect(DarkbloomMDMRemoval.target(in: Data("not a profile".utf8), coordinatorURL: coordinator) == nil)
        let appProvisioning: [String: Any] = ["ProfileIdentifier": "io.darkbloom.enroll",
                                            "ProfileItems": [["PayloadType": "provisioning"]]]
        #expect(try target([appProvisioning]) == nil)
    }

    @Test func originalEnrollmentPlistShapeIsAlsoRecognized() throws {
        let original: [String: Any] = [
            "PayloadIdentifier": "io.darkbloom.enroll", "PayloadType": "Configuration",
            "PayloadContent": [["PayloadIdentifier": "io.darkbloom.enroll.mdm",
                                "PayloadType": "com.apple.mdm",
                                "ServerURL": "https://api.darkbloom.dev/mdm/connect"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
        #expect(DarkbloomMDMRemoval.target(in: data, coordinatorURL: coordinator)?.identifier == "io.darkbloom.enroll")
    }

    @Test func administratorAccessPrecedesOnlyTheFixedRead() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["_computerlevel": [profile()]],
                                                      format: .xml, options: 0)
        var calls: [String] = []
        let selected = DarkbloomMDMRemoval.installedTarget(
            coordinatorURL: coordinator, allowAdministratorPrompt: true,
            beforeAdministratorPrompt: { calls.append("notice") },
            read: { executable, args, showErrors in
                calls.append("read \(executable) \(args.joined(separator: " ")) errors=\(showErrors)")
                return executable == "/usr/bin/sudo" ? xml : nil
            },
            readAuthenticated: { arguments in
                calls.append("sudo \(arguments.joined(separator: " "))")
                return xml
            })
        #expect(selected?.identifier == DarkbloomMDMRemoval.profileIdentifier)
        #expect(calls == [
            "read /usr/bin/profiles show -type configuration -output stdout-xml errors=false",
            "notice", "sudo show -type configuration -output stdout-xml -all",
        ])

        calls.removeAll()
        let denied = DarkbloomMDMRemoval.installedTarget(
            coordinatorURL: coordinator, allowAdministratorPrompt: true,
            beforeAdministratorPrompt: { calls.append("notice") },
            read: { executable, _, _ in calls.append("read \(executable)"); return nil },
            readAuthenticated: { _ in calls.append("sudo"); return nil })
        #expect(denied == nil)
        #expect(calls == ["read /usr/bin/profiles", "notice", "sudo"])
    }
}
