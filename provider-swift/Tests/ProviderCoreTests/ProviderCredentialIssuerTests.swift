import Foundation
import Testing
@testable import ProviderCore

extension ProviderCredentialStoreTests {
    @Test("Coordinator issuers omit only the normalized scheme's default port", arguments: [
        ("http://127.0.0.1:54321", "http://127.0.0.1:54321"),
        ("ws://127.0.0.1:54321/ws/provider", "http://127.0.0.1:54321"),
        (" \nWSS://Issuer.Example:443/ws/provider?region=one#fragment\t", "https://issuer.example"),
        ("https://Issuer.Example/other/path/", "https://issuer.example"),
        ("wss://Issuer.Example/ws/provider", "https://issuer.example"),
        ("https://Issuer.Example:443/", "https://issuer.example"),
        ("https://Issuer.Example:0443/", "https://issuer.example"),
        ("http://Issuer.Example/", "http://issuer.example"),
        ("ws://Issuer.Example/ws/provider", "http://issuer.example"),
        ("http://Issuer.Example:80/", "http://issuer.example"),
        ("ws://Issuer.Example:80/ws/provider", "http://issuer.example"),
        ("ws://Issuer.Example:080/ws/provider", "http://issuer.example"),
        ("https://Issuer.Example:8443/", "https://issuer.example:8443"),
        ("wss://Issuer.Example:8443/ws/provider", "https://issuer.example:8443"),
        ("http://Issuer.Example:8080/", "http://issuer.example:8080"),
        ("ws://Issuer.Example:8080/ws/provider", "http://issuer.example:8080"),
        ("https://Issuer.Example:80/", "https://issuer.example:80"),
        ("wss://Issuer.Example:80/ws/provider", "https://issuer.example:80"),
        ("http://Issuer.Example:443/", "http://issuer.example:443"),
        ("ws://Issuer.Example:443/ws/provider", "http://issuer.example:443"),
        ("https://[2001:DB8::1]:443/api/", "https://[2001:db8::1]"),
        ("wss://[2001:DB8::1]:443/ws/provider", "https://[2001:db8::1]"),
        ("http://[::1]:80/", "http://[::1]"),
        ("ws://[::1]:80/ws/provider", "http://[::1]"),
        ("ws://[::1]:54321/ws/provider", "http://[::1]:54321"),
        ("https://[2001:DB8::1]:8443/api/", "https://[2001:db8::1]:8443"),
    ])
    func canonicalIssuerPorts(input: String, expected: String) throws {
        let issuer = try canonicalCoordinatorIssuer(input)
        #expect(issuer == expected)
        #expect(try canonicalCoordinatorIssuer(issuer) == issuer)
    }

    @Test("Recovery accepts a legacy default-port binding without using its old token", arguments: [
        ("https://issuer.example:443", "https://issuer.example"),
        ("http://issuer.example:80", "http://issuer.example"),
    ])
    func defaultPortRecovery(stored: String, origin: String) async throws {
        try await withCredentialFiles { _ in
            try ProviderIssuerStore.save(stored)
            try AuthTokenStore.save("old-incomplete-token")
            let original = try RecoveryOriginalFiles()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(for: origin))
            #expect(try RecoveryOriginalFiles() == original)
            #expect(throws: ProviderCredentialStoreError.incompleteCredential) {
                try ProviderCredentialStore.authenticationToken(for: origin)
            }
            try recovery.publish(token: "fresh-authorized-token", accountID: "fresh-account")
            #expect(try ProviderCredentialStore.load(for: origin) == ProviderCredential(
                token: "fresh-authorized-token", accountID: "fresh-account", issuer: origin
            ))
        }
    }

    @Test("Recovery does not repair non-origin or mismatched stored issuers", arguments: [
        "https://issuer.example:8443", "https://issuer.example:443/path",
        "https://issuer.example:443?query=1", "HTTPS://issuer.example:443",
        "https://user@issuer.example:443", "http://issuer.example:443",
    ])
    func invalidLegacyIssuerRecovery(stored: String) async throws {
        try await withCredentialFiles { _ in
            try ProviderIssuerStore.save(stored)
            try AuthTokenStore.save("old-incomplete-token")
            let original = try RecoveryOriginalFiles()
            #expect(throws: ProviderCredentialStoreError.issuerMismatch(
                expected: "https://issuer.example", actual: stored
            )) {
                try ProviderCredentialRecovery.prepare(for: "https://issuer.example")
            }
            #expect(try RecoveryOriginalFiles() == original)
        }
    }

    @Test("Invalid coordinator URLs remain rejected", arguments: [
        "", "/ws/provider", "localhost:1234", "https:///no-host", "ftp://issuer.example",
        "https://user:password@issuer.example:443", "http://user@issuer.example:80",
        "http://@issuer.example:80", "http://issuer.example:bad", "http://[::1",
    ])
    func invalidIssuerURLs(input: String) throws {
        #expect(throws: ProviderCredentialStoreError.invalidCoordinatorURL) {
            try canonicalCoordinatorIssuer(input)
        }
    }

    @Test("Default ports publish the same credential origin as omitted ports", arguments: [
        ("https://issuer.example:443", "https://issuer.example"),
        ("wss://issuer.example:443", "https://issuer.example"),
        ("http://issuer.example:80", "http://issuer.example"),
        ("ws://issuer.example:80", "http://issuer.example"),
    ])
    func defaultPortPublication(endpoint: String, issuer: String) async throws {
        try await withCredentialFiles { _ in
            let expected = ProviderCredential(token: "token-a", accountID: "account-a", issuer: issuer)
            for savedURL in [endpoint, issuer] {
                try ProviderCredentialStore.save(
                    token: expected.token, accountID: expected.accountID, coordinatorURL: savedURL
                )
                #expect(ProviderIssuerStore.load() == issuer)
                #expect(try ProviderCredentialStore.load() == expected)
                #expect(try ProviderCredentialStore.load(for: issuer) == expected)
                #expect(try ProviderCredentialStore.load(for: endpoint + "/ws/provider") == expected)
                #expect(try ProviderCredentialStore.authenticationToken(for: issuer) == expected.token)
                try ProviderCredentialStore.delete(matching: expected)
            }
        }
    }

    @Test("Legacy explicit-default issuers load without rewriting the credential snapshot", arguments: [
        ("https://issuer.example:443", "https://issuer.example"),
        ("http://issuer.example:80", "http://issuer.example"),
        ("https://[::1]:443", "https://[::1]"),
        ("http://[::1]:80", "http://[::1]"),
    ])
    func legacyDefaultPortCredential(storedIssuer: String, origin: String) async throws {
        try await withCredentialFiles { _ in
            try ProviderAccountStore.save("account-a")
            try ProviderIssuerStore.save(storedIssuer)
            try AuthTokenStore.save("token-a")
            let original = try RecoveryOriginalFiles()
            let expected = ProviderCredential(token: "token-a", accountID: "account-a", issuer: storedIssuer)
            #expect(try ProviderCredentialStore.load() == expected)
            let websocket = origin.replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://")
            for endpoint in [origin, storedIssuer, websocket + "/ws/provider"] {
                #expect(try ProviderCredentialStore.load(for: endpoint) == expected)
                #expect(try ProviderCredentialStore.authenticationToken(for: endpoint) == expected.token)
            }
            #expect(try ProviderCredentialRecovery.prepare(for: origin) == nil)
            #expect(try RecoveryOriginalFiles() == original)
            try ProviderCredentialStore.delete(matching: expected)
            #expect(try ProviderCredentialStore.load() == nil)
            #expect(ProviderAccountStore.load() == nil)
            #expect(ProviderIssuerStore.load() == nil)
        }
    }

    @Test("Legacy default ports do not authorize other origins", arguments: [
        "https://issuer.example:8443", "wss://issuer.example:80",
        "http://issuer.example", "http://issuer.example:443", "ws://issuer.example:80",
        "https://other.example:443",
    ])
    func legacyDefaultPortIssuerMismatch(endpoint: String) async throws {
        try await withCredentialFiles { _ in
            try ProviderAccountStore.save("account-a")
            try ProviderIssuerStore.save("https://issuer.example:443")
            try AuthTokenStore.save("token-a")
            let original = try RecoveryOriginalFiles()
            let expectedIssuer = try canonicalCoordinatorIssuer(endpoint)
            #expect(throws: ProviderCredentialStoreError.issuerMismatch(
                expected: expectedIssuer, actual: "https://issuer.example:443"
            )) {
                try ProviderCredentialStore.authenticationToken(for: endpoint)
            }
            #expect(try RecoveryOriginalFiles() == original)
        }
    }

    @Test("Legacy port handling does not turn non-origin metadata into a valid binding", arguments: [
        "https://issuer.example:443/", "https://issuer.example:443/path",
        "https://issuer.example:443?query", "https://issuer.example:443#fragment",
        "https://user@issuer.example:443", "https://user:password@issuer.example:443",
        "https://Issuer.Example:443", "wss://issuer.example:443", "invalid URL",
    ])
    func legacyDefaultPortInvalidMetadata(storedIssuer: String) async throws {
        try await withCredentialFiles { _ in
            try ProviderAccountStore.save("account-a")
            try ProviderIssuerStore.save(storedIssuer)
            try AuthTokenStore.save("token-a")
            let original = try RecoveryOriginalFiles()
            #expect(throws: ProviderCredentialStoreError.issuerMismatch(
                expected: "https://issuer.example", actual: storedIssuer
            )) {
                try ProviderCredentialStore.authenticationToken(for: "https://issuer.example")
            }
            #expect(try RecoveryOriginalFiles() == original)
        }
    }

    @Test("Default port matching still requires a token and complete metadata", arguments: ["token", "account", "issuer"])
    func defaultPortMissingCredentialField(missing: String) async throws {
        try await withCredentialFiles { _ in
            if missing != "account" { try ProviderAccountStore.save("account-a") }
            if missing != "issuer" { try ProviderIssuerStore.save("https://issuer.example:443") }
            if missing != "token" { try AuthTokenStore.save("token-a") }
            let original = try RecoveryOriginalFiles()
            if missing == "token" {
                #expect(try ProviderCredentialStore.load(for: "https://issuer.example") == nil)
            } else {
                #expect(throws: ProviderCredentialStoreError.incompleteCredential) {
                    try ProviderCredentialStore.load(for: "https://issuer.example")
                }
            }
            #expect(try RecoveryOriginalFiles() == original)
        }
    }

    @Test("Legacy issuer matching preserves exact stale-logout checks", arguments: ["token", "account", "issuer"])
    func legacyDefaultPortStaleLogout(change: String) async throws {
        try await withCredentialFiles { _ in
            try ProviderAccountStore.save("account-a")
            try ProviderIssuerStore.save("https://issuer.example:443")
            try AuthTokenStore.save("token-a")
            let snapshot = try #require(try ProviderCredentialStore.load(for: "https://issuer.example"))
            switch change {
            case "token": try AuthTokenStore.save("token-b")
            case "account": try ProviderAccountStore.save("account-b")
            default: try ProviderIssuerStore.save("https://issuer.example")
            }
            let current = try RecoveryOriginalFiles()
            #expect(throws: ProviderCredentialStoreError.credentialChanged) {
                try ProviderCredentialStore.delete(matching: snapshot)
            }
            #expect(try RecoveryOriginalFiles() == current)
        }
    }
}
