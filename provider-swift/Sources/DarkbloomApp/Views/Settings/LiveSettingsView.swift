import SwiftUI

struct LiveSettingsView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Provider", value: snapshot.providerName)
                LabeledContent("Status", value: runStateTitle)
                LabeledContent("Availability", value: snapshot.availability.summary)
                LabeledContent("Trust", value: snapshot.trust.level)
                LabeledContent("Version", value: snapshot.version)
            }

            Section("Configuration") {
                Text("Use Availability, Models, and Local API in the main Darkbloom window to inspect or change provider behavior. Darkbloom does not expose controls here until they are wired to the provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Command") {
                    Text("darkbloom update")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Run the command in Terminal to check for and install a signed provider update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 470)
    }

    private var runStateTitle: String {
        switch snapshot.runState {
        case .online: "Online"
        case .serving: "Serving"
        case .paused: "Offline"
        case .scheduledOff: "Outside scheduled hours"
        case .attention: "Needs attention"
        case .stale: "Not responding"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .restarting: "Restarting"
        }
    }
}
