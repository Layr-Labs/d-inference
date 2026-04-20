/// ModelCatalogView — Rich model selection with fit indicators, download, and removal.
///
/// Shows the full model catalog with:
///   - Fit indicators (green = fits, red = too large for RAM)
///   - Download status (Downloaded, Available, Downloading)
///   - Download/Remove actions
///   - Model type badges (text, image, transcription)

import SwiftUI

struct ModelCatalogView: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var downloadingModel: String?
    @State private var downloadStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current model
            HStack {
                Text("Active Model:")
                    .foregroundColor(.warmInkLight)
                Text(viewModel.currentModel)
                    .fontWeight(.medium)
                Spacer()
                Button("Refresh") {
                    viewModel.modelManager.scanModels()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Model list
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(ModelCatalog.models, id: \.id) { entry in
                        modelRow(entry)
                    }
                }
            }

            // Download status
            if let downloading = downloadingModel {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(downloading)...")
                        .font(.caption)
                        .foregroundColor(.warmInkLight)
                    Spacer()
                }
            }

            if !downloadStatus.isEmpty && downloadingModel == nil {
                Text(downloadStatus)
                    .font(.caption)
                    .foregroundColor(.warmInkLight)
            }
        }
        .padding()
        .onAppear {
            viewModel.modelManager.scanModels()
        }
    }

    private func modelRow(_ entry: ModelCatalog.Entry) -> some View {
        let isDownloaded = viewModel.modelManager.availableModels.contains { $0.id == entry.id }
        let fits = entry.fitsInMemory(totalGB: viewModel.memoryGB)
        let isActive = viewModel.currentModel == entry.id
        let isDownloading = downloadingModel == entry.id
        let isDefault = ModelCatalog.defaultModel(ramGB: viewModel.memoryGB)?.id == entry.id

        return HStack(spacing: 12) {
            // Fit indicator
            Image(systemName: fits ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(fits ? .adaptiveTealAccent : .adaptiveError)
                .font(.caption)
                .help(fits ? "Fits in memory" : "Requires more RAM")

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .fontWeight(.medium)
                    Text(entry.modelType)
                        .font(.captionWarm)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(typeColor(entry.modelType).opacity(0.15))
                        .foregroundColor(typeColor(entry.modelType))
                        .cornerRadius(3)
                    if isDefault {
                        Text("default")
                            .font(.captionWarm)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.adaptiveCoral.opacity(0.15))
                            .foregroundColor(.adaptiveCoral)
                            .cornerRadius(3)
                    }
                }
                Text("\(String(format: "%.1f", entry.sizeGB)) GB  \(entry.architecture)")
                    .font(.captionWarm)
                    .foregroundColor(.warmInkLight)
            }

            Spacer()

            // Status badges
            if isDownloaded {
                Text("Downloaded")
                    .font(.captionWarm)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.adaptiveTealAccent.opacity(0.15))
                    .foregroundColor(.adaptiveTealAccent)
                    .cornerRadius(4)
            }

            // Actions
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.tealAccent)
                    .help("Currently active")
            } else if isDownloaded {
                HStack(spacing: 4) {
                    Button("Select") {
                        viewModel.currentModel = entry.id
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        Task { await removeModel(entry.id) }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.adaptiveError)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("Remove model")
                }
            } else if isDownloading {
                ProgressView().controlSize(.small)
            } else if fits {
                Button("Download") {
                    Task { await downloadModel(entry.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Text("Too large")
                    .font(.captionWarm)
                    .foregroundColor(.adaptiveError)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isActive ? Color.adaptiveCoral.opacity(0.06) : Color.clear)
        .cornerRadius(6)
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "text": return .adaptiveBlueAccent
        case "image": return .adaptivePurpleAccent
        case "transcription": return .adaptiveGold
        default: return .adaptiveInkFaint
        }
    }

    private func downloadModel(_ modelId: String) async {
        downloadingModel = modelId
        downloadStatus = ""

        do {
            let result = try await CLIRunner.run(["models", "download", "--model", modelId])
            if result.success {
                downloadStatus = "Downloaded \(modelId)"
                viewModel.modelManager.scanModels()
            } else {
                // Fallback: download from S3
                let s3Result = try await CLIRunner.run(["models", "download-s3", "--model", modelId])
                if s3Result.success {
                    downloadStatus = "Downloaded \(modelId) from CDN"
                    viewModel.modelManager.scanModels()
                } else {
                    downloadStatus = "Download failed: \(result.stderr)"
                }
            }
        } catch {
            downloadStatus = "Error: \(error.localizedDescription)"
        }

        downloadingModel = nil
    }

    private func removeModel(_ modelId: String) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheDir = home.appendingPathComponent(".cache/huggingface/hub")
        let dirName = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let modelDir = cacheDir.appendingPathComponent(dirName)

        do {
            try FileManager.default.removeItem(at: modelDir)
            viewModel.modelManager.scanModels()
            if viewModel.currentModel == modelId {
                viewModel.currentModel = "None"
            }
        } catch {
            downloadStatus = "Failed to remove: \(error.localizedDescription)"
        }
    }
}
