import Foundation
import ProviderCore

extension DesktopAccountCredential {
  /// Only attach identity returned for this exact coordinator and account session.
  func withIdentity(_ value: JSONValue, base: String, token: String) -> Self {
    guard self.base == base, self.token == token,
      let email = value.field("email").text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !email.isEmpty else { return self }
    var updated = self
    updated.email = email
    return updated
  }
}

extension DesktopBackend {
  func recordAccountIdentity(_ value: JSONValue, base: String, token: String) {
    guard let credential = DesktopAccountCredential.load(base: base) else { return }
    let updated = credential.withIdentity(value, base: base, token: token)
    guard updated.email != credential.email else { return }
    try? DesktopStorage.write(updated, name: DesktopAccountCredential.filename(base: base))
  }

  /// Hydrate older logins and stopped Macs without introducing another coordinator API.
  /// This joins the same cached/in-flight ledger read used by earnings and session stats.
  func refreshAccountIdentityIfNeeded(base: String, now: Date) {
    guard let credential = DesktopAccountCredential.load(base: base), credential.email == nil,
      accountIdentityRead == nil, now.timeIntervalSince(accountIdentityReadAt) >= 30 else { return }
    accountIdentityReadAt = now
    let generation = resourceGeneration
    accountIdentityRead = Task {
      defer { if generation == resourceGeneration { accountIdentityRead = nil } }
      _ = try? await accountEarnings(base: base, token: credential.token)
    }
  }
}
