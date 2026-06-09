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
        let modelDir = URL(fileURLWithPath: args[1])
        let mediaPaths = args[2].split(separator: ",").map { String($0) }
        let isVideo = mediaPaths.count == 1
            && videoExtensions.contains((mediaPaths[0] as NSString).pathExtension.lowercased())
        let defaultPrompt =
            isVideo
            ? "Describe what is happening in this video."
            : "Describe this image in detail. What objects, animals, colors, and any text do you see?"
        let prompt = args.count >= 4 ? args[3] : defaultPrompt

        do {
            let t0 = Date()
            err("[vlm-smoke] loading VLM from \(modelDir.lastPathComponent) ...")
            let container = try await VLMModelFactory.shared.loadContainer(
                from: modelDir,
                using: LocalTokenizerLoader()
            )
            err(String(format: "[vlm-smoke] loaded in %.1fs", Date().timeIntervalSince(t0)))

            // NOTE: do not read `userInput.images/videos` after building it.
            // `main()` is `@MainActor`, so any post-construction read binds
            // `userInput` to the main actor and `container.prepare(input:)`
            // then fails to compile with "sending 'userInput' risks causing
            // data races". `mediaPaths` is logged here instead, before the
            // value is built, so it flows straight into `prepare`.
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
            let maxTok = Int(env["VLM_MAXTOK"] ?? "") ?? 220
            let repPenDesc: String = repPen == nil ? "none" : "\(repPen!)"
            err("[vlm-smoke] sampling: temp=\(temp) repPen=\(repPenDesc) maxTokens=\(maxTok)")
            let params = GenerateParameters(
                maxTokens: maxTok, temperature: temp, repetitionPenalty: repPen)
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
        } catch {
            err("[vlm-smoke] ERROR: \(error)")
            exit(1)
        }
    }
}
