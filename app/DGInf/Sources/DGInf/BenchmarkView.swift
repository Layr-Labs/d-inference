/// BenchmarkView — Run standardized benchmarks and display results.
///
/// Wraps `dginf-provider benchmark` with a GUI showing real-time
/// progress and results: prefill TPS, decode TPS, time-to-first-token.

import SwiftUI

struct BenchmarkView: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var isRunning = false
    @State private var outputLines: [String] = []
    @State private var benchmarkProcess: Process?
    @State private var results: BenchmarkResults?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Provider Benchmark")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if isRunning {
                    Button("Cancel") {
                        cancelBenchmark()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await runBenchmark() }
                    } label: {
                        Label("Run Benchmark", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let results = results {
                // Results cards
                HStack(spacing: 16) {
                    metricCard("Prefill", value: results.prefillTPS, unit: "tok/s", icon: "arrow.right.circle")
                    metricCard("Decode", value: results.decodeTPS, unit: "tok/s", icon: "text.word.spacing")
                    metricCard("TTFT", value: results.ttft, unit: "ms", icon: "clock")
                }

                if !results.model.isEmpty {
                    HStack {
                        Text("Model:")
                            .foregroundColor(.secondary)
                        Text(results.model)
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                }
            }

            if isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Running benchmark...")
                        .foregroundColor(.secondary)
                }
            }

            // Live output
            if !outputLines.isEmpty {
                Divider()

                Text("Output")
                    .font(.headline)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(outputLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                    .frame(maxHeight: 200)
                    .onChange(of: outputLines.count) { _, _ in
                        if let last = outputLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 550, minHeight: 400)
    }

    // MARK: - Metric Card

    @ViewBuilder
    private func metricCard(_ title: String, value: Double, unit: String, icon: String) -> some View {
        let content = VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .symbolEffect(.bounce, value: value)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            if value > 0 {
                Text(String(format: "%.1f", value))
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("--")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        if #available(macOS 26.0, *) {
            content
                .padding(4)
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            GroupBox { content }
        }
    }

    // MARK: - Benchmark Execution

    private func runBenchmark() async {
        isRunning = true
        outputLines = []
        results = nil

        do {
            let proc = try CLIRunner.stream(["benchmark"]) { line in
                Task { @MainActor in
                    outputLines.append(line)
                    parseResultLine(line)
                }
            }
            benchmarkProcess = proc

            // Wait for completion on background thread
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    proc.waitUntilExit()
                    continuation.resume()
                }
            }
        } catch {
            outputLines.append("Error: \(error.localizedDescription)")
        }

        benchmarkProcess = nil
        isRunning = false
    }

    private func cancelBenchmark() {
        benchmarkProcess?.terminate()
        benchmarkProcess = nil
        isRunning = false
        outputLines.append("-- Benchmark cancelled --")
    }

    /// Parse benchmark output lines for metrics.
    ///
    /// Expected formats from the CLI:
    ///   Prefill: 1234.5 tok/s
    ///   Decode: 56.7 tok/s
    ///   Time to first token: 123 ms
    ///   Model: mlx-community/Qwen3.5-4B-4bit
    private func parseResultLine(_ line: String) {
        let lower = line.lowercased()

        if results == nil {
            results = BenchmarkResults()
        }

        if lower.contains("prefill") {
            if let val = extractNumber(from: line) {
                results?.prefillTPS = val
            }
        } else if lower.contains("decode") && !lower.contains("decoding") {
            if let val = extractNumber(from: line) {
                results?.decodeTPS = val
            }
        } else if lower.contains("time to first token") || lower.contains("ttft") {
            if let val = extractNumber(from: line) {
                results?.ttft = val
            }
        } else if lower.contains("model:") || lower.contains("model =") {
            let parts = line.components(separatedBy: CharacterSet(charactersIn: ":="))
            if let modelPart = parts.last?.trimmingCharacters(in: .whitespaces), !modelPart.isEmpty {
                results?.model = modelPart
            }
        }

        // Also try parsing "X tok/s" or "X tokens/s" patterns
        if let range = line.range(of: #"(\d+\.?\d*)\s*(tok/s|tokens/s)"#, options: .regularExpression) {
            let match = String(line[range])
            if let val = extractNumber(from: match) {
                if lower.contains("prefill") || lower.contains("prompt") {
                    results?.prefillTPS = val
                } else if results?.decodeTPS == 0 {
                    results?.decodeTPS = val
                }
            }
        }
    }

    private func extractNumber(from text: String) -> Double? {
        let pattern = #"(\d+\.?\d*)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(text[range])
    }
}

struct BenchmarkResults {
    var prefillTPS: Double = 0
    var decodeTPS: Double = 0
    var ttft: Double = 0
    var model: String = ""
}
