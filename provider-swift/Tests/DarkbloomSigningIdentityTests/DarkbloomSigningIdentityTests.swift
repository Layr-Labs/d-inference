import Foundation
import Testing

@testable import DarkbloomSigningIdentity

#if canImport(Security)
import Security
#endif

@Suite("Darkbloom signing identity")
struct DarkbloomSigningIdentityTests {
    @Test("the requirement pins the identifier, the team and the signing certificate")
    func requirementPinsTheCertificate() {
        #expect(
            DarkbloomSigningIdentity.requirement(identifier: "io.darkbloom.provider")
                == #"anchor apple generic and identifier "io.darkbloom.provider" "#
                    + #"and certificate leaf[subject.OU] = "SLDQ2GJ6TL" "#
                    + #"and certificate leaf = H"95b67556e04653f56ba5411d20d33dd263ef6e2a""#
        )
    }

    @Test("every listed certificate is a distinct lowercase SHA-1")
    func certificateListIsWellFormed() {
        let pins = DarkbloomSigningIdentity.certificateSHA1s
        #expect(!pins.isEmpty)
        #expect(Set(pins).count == pins.count)
        for pin in pins {
            #expect(pin.count == 40)
            #expect(pin.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test("several certificates are alternatives inside one clause")
    func severalCertificatesAreParenthesized() {
        #expect(
            DarkbloomSigningIdentity.certificateClause(["aa", "bb"])
                == #"(certificate leaf = H"aa" or certificate leaf = H"bb")"#
        )
        #expect(DarkbloomSigningIdentity.certificateClause(["aa"]) == #"certificate leaf = H"aa""#)
    }

    #if canImport(Security)
    @Test("macOS compiles the requirement, with one certificate and with two")
    func requirementCompiles() throws {
        let shipped = DarkbloomSigningIdentity.requirement(identifier: "io.darkbloom.fan-helper")
        let rotation =
            #"anchor apple generic and identifier "io.darkbloom.provider" and "#
            + DarkbloomSigningIdentity.certificateClause([
                String(repeating: "a", count: 40), String(repeating: "b", count: 40),
            ])
        for text in [shipped, rotation] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(requirement != nil)
        }
    }

    /// A valid Apple-anchored signature that is not Darkbloom's must not
    /// satisfy the requirement, even under its own signing identifier. The
    /// certificate clause must refuse it by itself: an unlisted certificate
    /// of the Darkbloom team passes every other clause.
    @Test("a valid signature from another signer does not satisfy the requirement")
    func otherSignerIsRefused() throws {
        var code: SecStaticCode?
        let systemBinary = URL(fileURLWithPath: "/usr/bin/true") as CFURL
        try #require(SecStaticCodeCreateWithPath(systemBinary, [], &code) == errSecSuccess)
        let signed = try #require(code)
        func validity(under text: String) throws -> OSStatus {
            var requirement: SecRequirement?
            try #require(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            return SecStaticCodeCheckValidity(signed, [], requirement)
        }

        let ownIdentifier = #"anchor apple generic and identifier "com.apple.true""#
        let listedCertificate = DarkbloomSigningIdentity.certificateClause(
            DarkbloomSigningIdentity.certificateSHA1s)
        #expect(try validity(under: ownIdentifier) == errSecSuccess)
        #expect(try validity(under: ownIdentifier + " and " + listedCertificate) == errSecCSReqFailed)
        #expect(
            try validity(under: DarkbloomSigningIdentity.requirement(identifier: "com.apple.true"))
                == errSecCSReqFailed
        )
    }
    #endif
}
