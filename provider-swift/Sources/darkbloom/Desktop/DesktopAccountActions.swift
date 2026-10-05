import Foundation
import ProviderCore

extension DesktopBackend {
  func executeAccountAction(_ request: DesktopAction) async throws {
    if request.action == "account-signin" {
        let config = try configuration().config
        let base = coordinatorHTTPBase(config.coordinator.url)
        let token = try await performDeviceCodeLogin(coordinatorURL: base, onDisplayCode: { [weak self] code, url, seconds in
          Task { await self?.setLink(request.id, .dict(["url": .string(url), "code": .string(code), "expires_at": .number(Date().timeIntervalSince1970 + Double(seconds)), "state": .string("waiting")])) }
        }, purpose: "desktop_account")
        try Task.checkCancellation()
        try DesktopAccountCredential.save(token: token, base: base)
        clearAccountResources()
        link = .null
        complete(request.id, code: 0, message: "Signed in.")
    } else {
        let base = coordinatorHTTPBase(try configuration().config.coordinator.url)
        let credential = DesktopAccountCredential.load(base: base)
        try DesktopAccountCredential.remove(base: base)
        clearAccountResources()
        // Local sign-out succeeds offline; server-side revocation is attempted with a bounded request.
        if let credential { try? await Self.revokeAccount(base: base, token: credential.token) }
        complete(request.id, code: 0, message: "Signed out.")

    }
  }
}
