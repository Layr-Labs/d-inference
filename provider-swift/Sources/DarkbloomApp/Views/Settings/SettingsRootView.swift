import SwiftUI

struct SettingsRootView: View {
    let providerStore: ProviderStore
    let showsPreviewControls: Bool

    @State private var selectedSection = SettingsSection.general

    var body: some View {
        if showsPreviewControls {
            TabView(selection: $selectedSection) {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsSection.general)

                LocalAPISettingsView()
                    .tabItem { Label("Local API", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .tag(SettingsSection.localAPI)

                AccountSecuritySettingsView()
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(SettingsSection.account)

                UpdateSettingsView(installedVersion: providerStore.snapshot.version)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                    .tag(SettingsSection.updates)

                AdvancedSettingsView()
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                    .tag(SettingsSection.advanced)
            }
            .frame(width: 620, height: 470)
        } else {
            LiveSettingsView(snapshot: providerStore.snapshot)
        }
    }
}

private enum SettingsSection: Hashable {
    case general
    case localAPI
    case account
    case updates
    case advanced
}

private struct SettingsForm<Content: View>: View {
    let showsPreviewNotice: Bool
    let content: Content

    init(
        showsPreviewNotice: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.showsPreviewNotice = showsPreviewNotice
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPreviewNotice {
                SettingsPreviewNotice()
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }

            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("darkbloom.settings.openAtLogin") private var openAtLogin = true
    @AppStorage("darkbloom.settings.launchDestination") private var launchDestination = "overview"

    var body: some View {
        SettingsForm(showsPreviewNotice: false) {
            Section("Sample app preferences") {
                Toggle("Open Darkbloom when I log in", isOn: $openAtLogin)

                Picker("Open to", selection: $launchDestination) {
                    Text("Overview").tag("overview")
                    Text("Chat").tag("chat")
                    Text("Last viewed screen").tag("last")
                }
            }

            Section {
                Text("Open at login and the launch destination are stored for this UI preview only. They do not change login items, window behavior, or a running provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum LocalAPIAccessPreference: String, CaseIterable {
    case thisMac = "this-mac"
    case allInterfaces = "all-interfaces"
    case custom

    var title: String {
        switch self {
        case .thisMac: "Only this Mac"
        case .allInterfaces: "All network interfaces"
        case .custom: "Specific address"
        }
    }
}

private struct LocalAPISettingsView: View {
    @AppStorage("darkbloom.settings.localEndpoint") private var localEndpointEnabled = true
    @AppStorage("darkbloom.settings.localPort") private var localPort = 8000
    @AppStorage("darkbloom.settings.localMode") private var localMode = LocalAPIMode.unified.rawValue
    @AppStorage("darkbloom.settings.localAccess") private var accessRawValue = LocalAPIAccessPreference.thisMac.rawValue
    @AppStorage("darkbloom.settings.localCustomBind") private var customBind = "100.64.0.2"
    @AppStorage("darkbloom.settings.localAuthentication") private var authenticationEnabled = true

    private var access: LocalAPIAccessPreference {
        LocalAPIAccessPreference(rawValue: accessRawValue) ?? .thisMac
    }

    private var bindAddress: String {
        switch access {
        case .thisMac: "127.0.0.1"
        case .allInterfaces: "0.0.0.0"
        case .custom: customBind.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var body: some View {
        SettingsForm {
            Section("Sample endpoint configuration") {
                Toggle("Enable the local OpenAI-compatible API", isOn: $localEndpointEnabled)

                if localEndpointEnabled {
                    Picker("Mode", selection: $localMode) {
                        Text("Local + network").tag(LocalAPIMode.unified.rawValue)
                        Text("Local only").tag(LocalAPIMode.directOnly.rawValue)
                    }

                    Picker("Access", selection: $accessRawValue) {
                        ForEach(LocalAPIAccessPreference.allCases, id: \.rawValue) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }

                    if access == .custom {
                        TextField("Bind address", text: $customBind)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Bind address") {
                        Text(bindAddress.isEmpty ? "Not set" : bindAddress)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    LabeledContent("Same-Mac base URL") {
                        Text("http://127.0.0.1:\(localPort)/v1")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Stepper("Port: \(localPort)", value: $localPort, in: 1024 ... 65535)
                    Toggle("Require an API key for inference", isOn: $authenticationEnabled)
                }
            }

            if localEndpointEnabled, access != .thisMac {
                Section {
                    Label(
                        "Network access uses plain HTTP with no built-in TLS. Keep API-key authentication on and use a trusted network or secure overlay.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(ProductPalette.warning)
                }
            }

            if localEndpointEnabled, !authenticationEnabled {
                Section {
                    Label(
                        "Without an API key, any local process or reachable webpage can submit inference. Use this only in a trusted, air-gapped environment.",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .foregroundStyle(ProductPalette.critical)
                }
            }

            Section {
                Text("These settings are stored for this UI preview only. They do not start, stop, bind, or reconfigure a provider process.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccountSecuritySettingsView: View {
    var body: some View {
        SettingsForm {
            Section("Planned account connection") {
                LabeledContent("Darkbloom account") {
                    Label("Not checked in preview", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Planned hardware verification") {
                LabeledContent("Verification profile") {
                    Label("Not checked in preview", systemImage: "shield.lefthalf.filled")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Trust level", value: "Not read in preview")
            }

            Section {
                Text("A connected build will read current account, MDM profile, and hardware-trust status. This preview does not infer those states from onboarding history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UpdateSettingsView: View {
    let installedVersion: String

    @AppStorage("darkbloom.settings.autoUpdates") private var autoUpdates = true
    @AppStorage("darkbloom.settings.betaUpdates") private var betaUpdates = false

    var body: some View {
        SettingsForm {
            Section("Sample update preferences") {
                Toggle("Automatically install Darkbloom updates", isOn: $autoUpdates)
                Toggle("Receive beta updates", isOn: $betaUpdates)
                LabeledContent("Sample version", value: installedVersion)
            }

            Section {
                Text("These controls do not select an update channel or install software. A connected build will verify updates before replacing the provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AdvancedSettingsView: View {
    @AppStorage("darkbloom.settings.memoryReserveGB") private var memoryReserve = 4.0
    @AppStorage("darkbloom.settings.maxResidentModels") private var residentModels = 2
    @AppStorage("darkbloom.settings.betaFeatures") private var betaFeatures = false

    var body: some View {
        SettingsForm {
            Section("Sample memory preferences") {
                LabeledContent("Reserve for macOS") {
                    Text("\(memoryReserve, specifier: "%.0f") GB")
                        .monospacedDigit()
                }
                Slider(value: $memoryReserve, in: 2 ... 16, step: 1)
                Stepper("Keep up to \(residentModels) models resident", value: $residentModels, in: 1 ... 3)
            }

            Section("Sample developer preferences") {
                Toggle("Enable beta features", isOn: $betaFeatures)
            }

            Section {
                Text("These values are not applied to model loading, memory limits, or provider behavior. Connected runtime controls are planned for a later build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
