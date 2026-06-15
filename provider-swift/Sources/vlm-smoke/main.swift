// vlm-smoke — throwaway harness to test Gemma 4 multimodal (VLM) inference
// with the mlx-swift-lm fork's MLXVLM library, loading from a LOCAL model
// directory (no network) and feeding an image OR video + text prompt.
//
// usage: vlm-smoke <modelDir> <image-or-video-path> [prompt]
//   - If the media path has a video extension (mp4/mov/m4v/3gp/webm), it is
//     fed as a video; otherwise as an image.
//   - Multiple comma-separated image paths are fed as multiple images.

import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import ProviderCore  // LocalTokenizerLoader (local, no-network tokenizer)

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@main
struct VLMSmoke {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "webm", "avi", "mkv"]

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            err("usage: vlm-smoke <modelDir> <image-or-video-path[,path2,...]> [prompt]")
            exit(2)
        }
        do {
            try await run(
                modelDirPath: args[1],
                mediaArg: args[2],
                promptArg: args.count >= 4 ? args[3] : nil
            )
        } catch {
            err("[vlm-smoke] ERROR: \(error)")
            exit(1)
        }
    }

    // `nonisolated` so `userInput` is constructed OUTSIDE any actor's region.
    // `main()` is @MainActor; on older toolchains (CI's macOS-26 Xcode) a
    // non-Sendable value built in an actor-isolated context cannot be sent
    // into `container.prepare(input:)` ("sending 'userInput' risks causing
    // data races"), even with no post-construction reads. In a nonisolated
    // async function the fresh value is in a disconnected region, which every
    // Swift 6.x compiler accepts. Same shape as upstream llm-tool's `run()`.
    nonisolated static func run(
        modelDirPath: String, mediaArg: String, promptArg: String?
    ) async throws {
        let modelDir = URL(fileURLWithPath: modelDirPath)
        let mediaPaths = mediaArg.split(separator: ",").map { String($0) }
        let isVideo = mediaPaths.count == 1
            && videoExtensions.contains((mediaPaths[0] as NSString).pathExtension.lowercased())
        let defaultPrompt =
            isVideo
            ? "Describe what is happening in this video."
            : "Describe this image in detail. What objects, animals, colors, and any text do you see?"
        let prompt = promptArg ?? defaultPrompt

        let t0 = Date()
        err("[vlm-smoke] loading VLM from \(modelDir.lastPathComponent) ...")
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: LocalTokenizerLoader()
        )
        err(String(format: "[vlm-smoke] loaded in %.1fs", Date().timeIntervalSince(t0)))

        let userInput: UserInput
        if isVideo {
            err("[vlm-smoke] preparing input (video: \(mediaPaths[0])) ...")
            let videoURL = URL(fileURLWithPath: mediaPaths[0])
            userInput = UserInput(chat: [.user(prompt, videos: [.url(videoURL)])])
        } else {
            err("[vlm-smoke] preparing input (\(mediaPaths.count) image(s)) ...")
            let images = mediaPaths.map { UserInput.Image.url(URL(fileURLWithPath: $0)) }
            userInput = UserInput(chat: [.user(prompt, images: images)])
        }
        let lmInput = try await container.prepare(input: userInput)

        err("[vlm-smoke] generating ...")
        let env = ProcessInfo.processInfo.environment
        let temp = Float(env["VLM_TEMP"] ?? "") ?? 0.0
        let repPen: Float? = Float(env["VLM_REPPEN"] ?? "")
        let presPen: Float? = Float(env["VLM_PRESPEN"] ?? "")
        let freqPen: Float? = Float(env["VLM_FREQPEN"] ?? "")
        let maxTok = Int(env["VLM_MAXTOK"] ?? "") ?? 220
        let repPenDesc: String = repPen == nil ? "none" : "\(repPen!)"
        err("[vlm-smoke] sampling: temp=\(temp) repPen=\(repPenDesc) presPen=\(presPen.map { "\($0)" } ?? "none") freqPen=\(freqPen.map { "\($0)" } ?? "none") maxTokens=\(maxTok)")
        let params = GenerateParameters(
            maxTokens: maxTok, temperature: temp, repetitionPenalty: repPen,
            presencePenalty: presPen, frequencyPenalty: freqPen)
        let stream = try await container.generate(input: lmInput, parameters: params)

        err("---OUTPUT-START---")
        var out = ""
        for await gen in stream {
            switch gen {
            case .chunk(let s):
                out += s
                FileHandle.standardOutput.write(Data(s.utf8))
            case .info(let info):
                err(String(format: "\n[vlm-smoke] %.1f tok/s, %d tokens",
                           info.tokensPerSecond, info.generationTokenCount))
            case .toolCall(let c):
                err("[vlm-smoke] toolCall: \(c)")
            @unknown default:
                break
            }
        }
        FileHandle.standardOutput.write(Data("\n".utf8))
        err("---OUTPUT-END--- (\(out.count) chars)")
    }
}
