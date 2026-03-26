/// LogViewerView — Streaming log viewer for provider output.
///
/// Reads `~/.dginf/provider.log` directly and supports tail-f style
/// streaming using a DispatchSource file monitor.

import SwiftUI

struct LogViewerView: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var logLines: [String] = []
    @State private var isStreaming = false
    @State private var searchText = ""
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var fileHandle: FileHandle?

    private var logFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dginf/provider.log").path
    }

    private var filteredLines: [String] {
        if searchText.isEmpty {
            return logLines
        }
        return logLines.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Provider Logs")
                    .font(.headline)

                Spacer()

                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                Toggle(isOn: $isStreaming) {
                    Label("Live", systemImage: "antenna.radiowaves.left.and.right")
                }
                .toggleStyle(.button)
                .onChange(of: isStreaming) { _, streaming in
                    if streaming {
                        startStreaming()
                    } else {
                        stopStreaming()
                    }
                }

                Button {
                    logLines = []
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear log display")

                Button {
                    loadLogFile()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
            }
            .padding(12)

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredLines.enumerated()), id: \.offset) { index, line in
                            logLineView(line)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: logLines.count) { _, _ in
                    if isStreaming, let lastIndex = filteredLines.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .background(Color(.textBackgroundColor))

            // Status bar
            HStack {
                Text("\(filteredLines.count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if isStreaming {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Live")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Spacer()

                Text(logFilePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.windowBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 400)
        .onAppear {
            loadLogFile()
        }
        .onDisappear {
            stopStreaming()
        }
    }

    private func logLineView(_ line: String) -> some View {
        let color: Color = {
            if line.contains("ERROR") || line.contains("error") { return .red }
            if line.contains("WARN") || line.contains("warn") { return .orange }
            if line.contains("INFO") { return .primary }
            if line.contains("DEBUG") { return .secondary }
            return .primary
        }()

        return Text(line)
            .foregroundColor(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadLogFile() {
        guard FileManager.default.fileExists(atPath: logFilePath) else {
            logLines = ["Log file not found: \(logFilePath)", "Start the provider to generate logs."]
            return
        }

        do {
            let content = try String(contentsOfFile: logFilePath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            // Show last 500 lines
            logLines = Array(lines.suffix(500))
        } catch {
            logLines = ["Failed to read log file: \(error.localizedDescription)"]
        }
    }

    private func startStreaming() {
        stopStreaming()

        guard FileManager.default.fileExists(atPath: logFilePath) else { return }

        let fd = open(logFilePath, O_RDONLY)
        guard fd >= 0 else { return }

        // Seek to end
        lseek(fd, 0, SEEK_END)

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fileHandle = handle

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )

        source.setEventHandler { [weak handle] in
            guard let handle = handle else { return }
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }

            let newLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            Task { @MainActor in
                logLines.append(contentsOf: newLines)
                // Cap at 2000 lines
                if logLines.count > 2000 {
                    logLines = Array(logLines.suffix(1500))
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileMonitor = source
    }

    private func stopStreaming() {
        fileMonitor?.cancel()
        fileMonitor = nil
        fileHandle = nil
    }
}
