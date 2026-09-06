import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Managed provider install layout")
struct ManagedProviderInstallLayoutTests {
    @Test("Canonical CLI is the real nested helper, with an exact compatibility alias")
    func canonicalPaths() {
        let home = URL(fileURLWithPath: "/Users/provider")
        let app = URL(fileURLWithPath: "/Users/provider/.darkbloom/Darkbloom.app")
        let nested = app.appendingPathComponent(
            "Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom"
        )
        #expect(ManagedProviderInstallLayout.appURL(homeDirectory: home) == app)
        #expect(ManagedProviderInstallLayout.cliURL(homeDirectory: home) == nested)
        #expect(ManagedProviderInstallLayout.cliURL(appBundleURL: app) == nested)
        #expect(ManagedProviderInstallLayout.cliPathComponents.joined(separator: "/")
            == ".darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom")
        #expect(ManagedProviderInstallLayout.legacyCLIURL(homeDirectory: home)
            == app.appendingPathComponent("Contents/MacOS/darkbloom"))
        #expect(ManagedProviderInstallLayout.helperAppRelativePath
            == "Contents/Helpers/DarkbloomProvider.app")
        #expect(ManagedProviderInstallLayout.helperInfoPlistRelativePath
            == "Contents/Helpers/DarkbloomProvider.app/Contents/Info.plist")
        #expect(ManagedProviderInstallLayout.helperProvisioningProfileRelativePath
            == "Contents/Helpers/DarkbloomProvider.app/Contents/embedded.provisionprofile")
        #expect(ManagedProviderInstallLayout.compatibilityCLISymlinkTarget
            == "../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom")
    }

    @Test("Outer app derivation recognizes exact nested and legacy CLI layouts", arguments: [
        "Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom",
        "Contents/MacOS/darkbloom",
    ])
    func outerApp(relativeExecutable: String) {
        // Intentionally nonexistent: this API is lexical, not an IO validator.
        let outer = URL(fileURLWithPath: "/private/var/nonexistent/Downloads/Darkbloom.app")
        #expect(ManagedProviderInstallLayout.outerAppURL(
            forExecutableURL: outer.appendingPathComponent(relativeExecutable)
        )?.path == outer.path)
    }

    @Test("Outer app derivation refuses ambiguous and malformed paths", arguments: [
        "/usr/local/bin/darkbloom",
        "/Users/provider/.darkbloom/bin/darkbloom",
        "/Downloads/Darkbloom.app/Contents/MacOS/DarkbloomApp",
        "/Downloads/Darkbloom.app/Contents/MacOS/darkbloom-enclave",
        "/Downloads/Darkbloom.app/Contents/Helpers/Other.app/Contents/MacOS/darkbloom",
        "/Downloads/Darkbloom.app/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom",
        "/Downloads/Darkbloom.app/Contents/Other/DarkbloomProvider.app/Contents/MacOS/darkbloom",
        "/Downloads/DarkbloomProvider.app/Contents/MacOS/darkbloom",
        "/Downloads/Darkbloom.app/Contents/Helpers/Darkbloom.app/Contents/MacOS/darkbloom",
        "/Downloads/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom/extra",
        "/Downloads/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/../Contents/MacOS/darkbloom",
    ])
    func rejectsMalformedOuterApp(path: String) {
        #expect(ManagedProviderInstallLayout.outerAppURL(
            forExecutableURL: URL(fileURLWithPath: path)
        ) == nil)
    }

    @Test("Outer app derivation refuses non-file URLs")
    func rejectsNonFileURL() throws {
        let url = try #require(URL(string: "https://example.com/Darkbloom.app/Contents/MacOS/darkbloom"))
        #expect(ManagedProviderInstallLayout.outerAppURL(forExecutableURL: url) == nil)
    }
}
