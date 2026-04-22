/// SettingsView — Configuration window for the Darkbloom provider.
///
/// Tabs:
///   - General: Coordinator URL, API key, auto-start on login
///   - Availability: Idle timeout, schedule
///   - Model: Full model catalog with fit indicators and download/remove
///   - Security: Security posture overview

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        TabView {
            GeneralTab(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AvailabilityTab(viewModel: viewModel)
                .tabItem {
                    Label("Availability", systemImage: "clock")
                }

            ModelCatalogView(viewModel: viewModel)
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            SecurityTab(viewModel: viewModel)
                .tabItem {
                    Label("Security", systemImage: "shield")
                }
        }
        .frame(minWidth: 550, idealWidth: 580, minHeight: 420)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        Form {
            Section {
                TextField("Coordinator URL:", text: $viewModel.coordinatorURL)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Connection")
                    .font(.display(18))
            }

            Section {
                Toggle("Start Darkbloom when you log in", isOn: $viewModel.autoStart)

                HStack {
                    Text("LaunchAgent:")
                        .foregroundColor(.warmInkLight)
                    Text(LaunchAgentManager.isInstalled ? "Installed" : "Not installed")
                        .font(.caption)
                        .foregroundColor(LaunchAgentManager.isInstalled ? .adaptiveTealAccent : .warmInkLight)
                }
            } header: {
                Text("Startup")
                    .font(.display(18))
            }

            Section {
                HStack {
                    Text("Provider Binary:")
                        .foregroundColor(.warmInkLight)
                    if let path = CLIRunner.resolveBinaryPath() {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.adaptiveTealAccent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not found")
                            .font(.caption)
                            .foregroundColor(.adaptiveError)
                    }
                }

                HStack {
                    Text("Version:")
                        .foregroundColor(.warmInkLight)
                    Text("v\(viewModel.updateManager.currentVersion)")
                        .font(.caption)
                    if viewModel.updateManager.updateAvailable {
                        Text("(update available)")
                            .font(.caption)
                            .foregroundColor(.adaptiveGold)
                    }
                }
            } header: {
                Text("Status")
                    .font(.display(18))
            }
        }
        .padding()
    }
}

// MARK: - Availability Tab

private struct AvailabilityTab: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var selectedTimeout: TimeInterval = 300

    var body: some View {
        Form {
            Section {
                Picker("Pause when user is active for:", selection: $selectedTimeout) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                    Text("30 minutes").tag(TimeInterval(1800))
                    Text("Never pause").tag(TimeInterval(0))
                }
                .onChange(of: selectedTimeout) { _, newValue in
                    viewModel.idleTimeoutSeconds = newValue
                }

                Text("When you're using your Mac, Darkbloom will pause inference to keep your machine responsive. It resumes automatically when you step away.")
                    .font(.captionWarm)
                    .foregroundColor(.warmInkLight)
            } header: {
                Text("Idle Detection")
                    .font(.display(18))
            }

            Section {
                Toggle("Enable schedule", isOn: $viewModel.scheduleEnabled)

                if viewModel.scheduleEnabled {
                    ForEach($viewModel.scheduleWindows) { $window in
                        ScheduleWindowRow(window: $window)
                    }
                    .onDelete { indices in
                        viewModel.scheduleWindows.remove(atOffsets: indices)
                    }

                    Button {
                        viewModel.scheduleWindows.append(ScheduleWindowModel.defaultWindow())
                    } label: {
                        Label("Add Window", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }

                Text("Set when your machine serves inference. Outside these windows, the provider disconnects and frees GPU memory. Requires provider restart to take effect.")
                    .font(.captionWarm)
                    .foregroundColor(.warmInkLight)
            } header: {
                Text("Schedule")
                    .font(.display(18))
            }
        }
        .padding()
        .onAppear {
            selectedTimeout = viewModel.idleTimeoutSeconds
        }
    }
}

// MARK: - Schedule Window Row

private struct ScheduleWindowRow: View {
    @Binding var window: ScheduleWindowModel

    private let hours: [String] = (0..<24).map { String(format: "%02d:00", $0) }
        + (0..<24).map { String(format: "%02d:30", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Day selector
            HStack(spacing: 4) {
                ForEach(ScheduleWindowModel.allDays, id: \.self) { day in
                    let isActive = window.activeDays.contains(day)
                    Button {
                        if isActive {
                            window.activeDays.removeAll { $0 == day }
                        } else {
                            window.activeDays.append(day)
                        }
                    } label: {
                        Text(ScheduleWindowModel.dayLabels[day] ?? day)
                            .font(.captionWarm)
                            .frame(width: 36, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(isActive ? .accentColor : .secondary)
                }
            }

            // Time range
            HStack {
                Picker("From", selection: $window.startTime) {
                    ForEach(sortedHours, id: \.self) { time in
                        Text(time).tag(time)
                    }
                }
                .frame(width: 120)

                Picker("To", selection: $window.endTime) {
                    ForEach(sortedHours, id: \.self) { time in
                        Text(time).tag(time)
                    }
                }
                .frame(width: 120)

                if window.isOvernight {
                    Text("(overnight)")
                        .font(.captionWarm)
                        .foregroundColor(.adaptiveGold)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var sortedHours: [String] {
        hours.sorted()
    }
}

// MARK: - Security Tab

private struct SecurityTab: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Security Posture")
                    .font(.display(18))
                Spacer()
                if viewModel.securityManager.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await viewModel.securityManager.refresh() }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            // Trust level
            if #available(macOS 26.0, *) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.securityManager.trustLevel.iconName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(trustColor)
                    VStack(alignment: .leading) {
                        Text(viewModel.securityManager.trustLevel.displayName)
                            .font(.display(18))
                            .fontWeight(.bold)
                            .foregroundColor(trustColor)
                        Text(trustDescription)
                            .font(.captionWarm)
                            .foregroundColor(.warmInkLight)
                    }
                }
                .padding(12)
                .glassEffect(.regular.tint(trustColor.opacity(0.15)), in: .rect(cornerRadius: 12))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.securityManager.trustLevel.iconName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(trustColor)
                    VStack(alignment: .leading) {
                        Text(viewModel.securityManager.trustLevel.displayName)
                            .font(.display(18))
                            .fontWeight(.bold)
                            .foregroundColor(trustColor)
                        Text(trustDescription)
                            .font(.captionWarm)
                            .foregroundColor(.warmInkLight)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                checkRow("SIP", viewModel.securityManager.sipEnabled)
                checkRow("Secure Enclave", viewModel.securityManager.secureEnclaveAvailable)
                checkRow("Secure Boot", viewModel.securityManager.secureBootEnabled)
                checkRow("MDM Enrolled", viewModel.securityManager.mdmEnrolled)
                checkRow("Node Key", viewModel.securityManager.nodeKeyExists)
                checkRow("Provider Binary", viewModel.securityManager.binaryFound)
            }

            Spacer()

            Button {
                openWindow(id: "doctor")
            } label: {
                Label("Run Full Diagnostics...", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .adaptiveTealAccent
        case .none: return .adaptiveError
        }
    }

    private var trustDescription: String {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return "All security checks pass. Your provider will receive inference requests."
        case .none: return "Not verified. Complete the setup wizard to enable inference routing."
        }
    }

    private func checkRow(_ label: String, _ enabled: Bool) -> some View {
        HStack {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(enabled ? .adaptiveTealAccent : .adaptiveError)
            Text(label)
            Spacer()
            Text(enabled ? "OK" : "Missing")
                .font(.captionWarm)
                .foregroundColor(enabled ? .warmInkLight : .adaptiveError)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .modifier(GlassRowModifier())
    }

    private struct GlassRowModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(in: .rect(cornerRadius: 8))
            } else {
                content
            }
        }
    }
}
