import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom login --json`: the NDJSON wire schema the macOS app decodes
/// (`AccountLinkEvent` in DarkbloomApp/Services/AccountLinkCLI.swift mirrors
/// this). Exactly the pinned keys, one line per event.
@Suite("Login command --json events")
struct LoginCommandTests {

    @Test("--json flag parses")
    func jsonFlagParses() throws {
        let command = try Darkbloom.parseAsRoot(["login", "--json"])
        let login = try #require(command as? Login)
        #expect(login.json)

        let human = try Darkbloom.parseAsRoot(["login"])
        let humanLogin = try #require(human as? Login)
        #expect(!humanLogin.json)
    }

    @Test("code event serializes with exactly event/user_code/verification_uri/expires_in")
    func codeEventLine() throws {
        let line = try LoginEventNDJSON.line(for: .code(
            userCode: "ABCD-EFGH",
            verificationURI: "https://app.darkbloom.dev/link",
            expiresIn: 900
        ))
        #expect(!line.contains("\n"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["event"] as? String == "code")
        #expect(object["user_code"] as? String == "ABCD-EFGH")
        #expect(object["verification_uri"] as? String == "https://app.darkbloom.dev/link")
        #expect((object["expires_in"] as? NSNumber)?.intValue == 900)
        #expect(Set(object.keys) == ["event", "user_code", "verification_uri", "expires_in"])
    }

    @Test("linked event serializes with exactly the event key")
    func linkedEventLine() throws {
        let line = try LoginEventNDJSON.line(for: .linked)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["event"] as? String == "linked")
        #expect(Set(object.keys) == ["event"])
    }

    @Test("error event serializes the message and collapses newlines to stay on one line")
    func errorEventLine() throws {
        let line = try LoginEventNDJSON.line(for: .error(message: "first line\nsecond line"))
        #expect(!line.contains("\n"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["event"] as? String == "error")
        #expect(object["message"] as? String == "first line second line")
        #expect(Set(object.keys) == ["event", "message"])
    }

    @Test("verification URLs keep unescaped slashes for readability")
    func eventLineDoesNotEscapeSlashes() throws {
        let line = try LoginEventNDJSON.line(for: .code(
            userCode: "WXYZ-1234",
            verificationURI: "https://example.test/a/b",
            expiresIn: 60
        ))
        #expect(line.contains("https://example.test/a/b"))
    }
}
