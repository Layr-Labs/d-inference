import AppKit
import SwiftUI

struct AppInstallationRecoveryView: View {
    let recovery: AppInstallationRecovery

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("Darkbloom is installed")
                .font(.title2.bold())
            Text(
                "The managed app could not open automatically. "
                    + "This downloaded copy is restricted to installation recovery."
            )
            Text("Installed app: \(recovery.destination.path)")
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack {
                Button("Open Installed Darkbloom") {
                    recovery.openInstalledApp()
                }
                .keyboardShortcut(.defaultAction)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(48)
    }
}
