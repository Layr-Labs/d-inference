import Foundation

extension SelfUpdater {
    func verifyDeclaredReleaseCapabilities(
        _ release: ReleaseInfo,
        app: URL?,
        executable: URL,
        fileManager: FileManager
    ) throws {
        let declarations = [
            release.hasApp,
            release.hasFanHelper,
            release.hasPagedKernel,
        ]
        guard declarations.contains(where: { $0 != nil }) else {
            return // Rows registered before capability derivation remain usable.
        }
        guard let expectedApp = release.hasApp,
              let expectedFan = release.hasFanHelper,
              let expectedPaged = release.hasPagedKernel
        else {
            throw UpdateError.replaceFailed(
                "release capability flags must be all present or all absent"
            )
        }

        let fanCode = try FanHelperCapabilityVerifier.binaryContainsCapability(
            executable
        )
        let pagedBinary = try Data(
            contentsOf: executable,
            options: [.mappedIfSafe]
        )
        let pagedCode =
            pagedBinary.range(of: Data("engine_v2_kv_backend".utf8)) != nil

        let fanMarker: Bool
        let fanHelper: Bool
        let pagedMarker: Bool
        let pagedResource: Bool
        if let app {
            fanMarker = fileManager.fileExists(
                atPath: app.appendingPathComponent(
                    FanHelperCapabilityVerifier.markerRelativePath
                ).path
            )
            fanHelper = fileManager.fileExists(
                atPath: app.appendingPathComponent(
                    FanHelperCapabilityVerifier.helperRelativePath
                ).path
            )
            pagedMarker = fileManager.fileExists(
                atPath: app.appendingPathComponent(
                    PackagedRuntimeSmoke.pagedCapabilityRelativePath
                ).path
            )
            pagedResource = fileManager.fileExists(
                atPath: app.appendingPathComponent(
                    "Contents/Resources/"
                        + PackagedRuntimeSmoke.mlxLMCommonBundleName
                        + "/pagedattention.metal"
                ).path
            )
        } else {
            fanMarker = false
            fanHelper = false
            pagedMarker = false
            pagedResource = false
        }

        guard fanCode == fanMarker, fanMarker == fanHelper else {
            throw UpdateError.replaceFailed(
                "fan-helper release capability is internally inconsistent"
            )
        }
        guard pagedCode == pagedMarker, pagedMarker == pagedResource else {
            throw UpdateError.replaceFailed(
                "paged-kernel release capability is internally inconsistent"
            )
        }

        let actual = (
            app: app != nil,
            fan: fanCode,
            paged: pagedCode
        )
        guard expectedApp == actual.app else {
            throw UpdateError.replaceFailed(
                "coordinator has_app=\(expectedApp) does not match "
                    + "the verified artifact (\(actual.app))"
            )
        }
        guard expectedFan == actual.fan else {
            throw UpdateError.replaceFailed(
                "coordinator has_fan_helper=\(expectedFan) does not match "
                    + "the verified artifact (\(actual.fan))"
            )
        }
        guard expectedPaged == actual.paged else {
            throw UpdateError.replaceFailed(
                "coordinator has_paged_kernel=\(expectedPaged) does not match "
                    + "the verified artifact (\(actual.paged))"
            )
        }
    }
}
