// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Runtime gate for the installed provider artifact. Release packaging runs
/// this through the staged app executable before publication.
public enum PackagedRuntimeSmoke {
    public static func runPagedKernel() throws {
        // Strictly inspect the installed app. Development search roots are
        // intentionally excluded so CI cannot pass by finding the build
        // directory after forgetting to package the bundle.
        var roots = [Bundle.main.bundleURL]
        roots.append(
            Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources",
                isDirectory: true))
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL)
        }
        try PagedAttentionKernel.runtimeSmoke(
            searchRoots: roots)
    }
}
