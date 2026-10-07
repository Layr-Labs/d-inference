import Foundation
import ProviderCore
import Testing
@testable import darkbloom

struct DesktopAccountIdentityTests {
  private let base = "https://coordinator.test"
  private var credential: DesktopAccountCredential {
    DesktopAccountCredential(token: "darkbloom-at-test", base: base, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
  }

  @Test func identityIsBoundToCoordinatorAndAccountCredential() {
    let payload: JSONValue = .dict(["email": .string(" owner@example.com ")])
    let original = credential
    let updated = original.withIdentity(payload, base: base, token: original.token)
    #expect(updated.email == "owner@example.com")
    #expect(updated.token == original.token)
    #expect(updated.expiresAt == original.expiresAt)
    #expect(original.withIdentity(payload, base: "https://other.test", token: original.token).email == nil)
    #expect(original.withIdentity(payload, base: base, token: "another-account-token").email == nil)
  }

  @Test func identitySurvivesRestartAndOlderCredentialFilesStillDecode() throws {
    let original = credential
    let legacy = try JSONSerialization.data(withJSONObject: ["token": original.token, "base": base, "expiresAt": original.expiresAt.timeIntervalSinceReferenceDate])
    #expect(try JSONDecoder().decode(DesktopAccountCredential.self, from: legacy).email == nil)
    let updated = original.withIdentity(.dict(["email": .string("owner@example.com")]), base: base, token: original.token)
    let saved = try JSONEncoder().encode(updated)
    #expect(try JSONDecoder().decode(DesktopAccountCredential.self, from: saved).email == "owner@example.com")
  }

  @Test func missingIdentityDoesNotInventEmailOrEraseLastVerifiedIdentity() {
    let original = credential
    #expect(original.withIdentity(.dict([:]), base: base, token: original.token).email == nil)
    let identified = original.withIdentity(.dict(["email": .string("owner@example.com")]), base: base, token: original.token)
    #expect(identified.withIdentity(.dict(["email": .null]), base: base, token: identified.token).email == "owner@example.com")
    #expect(identified.withIdentity(.dict(["email": .string("  ")]), base: base, token: identified.token).email == "owner@example.com")
  }
}
