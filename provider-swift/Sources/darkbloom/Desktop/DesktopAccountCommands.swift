import ArgumentParser
import Foundation
import ProviderCore

extension Desktop {
  struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sign in to the read-only desktop account dashboard.")
    @OptionGroup var configOptions: ConfigOptions
    mutating func run() async throws {
      let base = coordinatorHTTPBase(try loadRuntimeConfiguration(configPath: configOptions.config).config.coordinator.url)
      let token = try await performDeviceCodeLogin(coordinatorURL: base, onDisplayCode: { code, url, _ in
        print("Open \(url) and authorize desktop access with code \(code).")
      }, purpose: "desktop_account")
      try DesktopAccountCredential.save(token: token, base: base)
      print("Signed in to the desktop dashboard.")
    }
  }
  struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sign out of the desktop dashboard.")
    @OptionGroup var configOptions: ConfigOptions
    mutating func run() async throws {
      let base = coordinatorHTTPBase(try loadRuntimeConfiguration(configPath: configOptions.config).config.coordinator.url)
      let credential = DesktopAccountCredential.load(base: base)
      try DesktopAccountCredential.remove(base: base)
      if let credential { try? await DesktopBackend.revokeAccount(base: base, token: credential.token) }
      print("Signed out of the desktop dashboard.")
    }
  }
}
