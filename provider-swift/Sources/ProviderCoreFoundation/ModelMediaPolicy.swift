import Foundation
import CoreFoundation

/// Media capability is a serving policy, not a consequence of retaining a
/// vision configuration or its tensors in a checkpoint. Keep this pure so
/// discovery and template validation can share it without importing MLX.
public enum ModelMediaPolicy {
    public static let ownedQwen4ModelID = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"

    public static func isNativeQwen4Type(_ modelType: String?) -> Bool {
        guard let modelType = modelType?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return modelType == "qwen4_exp" || modelType == "qwen4_exp_text"
    }

    public static func advertisesMedia(_ configuration: [String: Any], modelID: String? = nil) -> Bool {
        if isNativeQwen4Type(configuration["model_type"] as? String) {
            // Restore only the owned full Flash-Next tower. Bare text types,
            // unknown identities, and missing/true text-only overlays stay cold
            // for media; retaining tensors alone does not qualify a checkpoint.
            guard modelID == ownedQwen4ModelID,
                (configuration["model_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "qwen4_exp",
                let overlay = configuration["language_model_only"] as? NSNumber,
                CFGetTypeID(overlay) == CFBooleanGetTypeID(), !overlay.boolValue,
                let vision = configuration["vision_config"] as? [String: Any],
                let text = configuration["text_config"] as? [String: Any],
                vision["model_type"] as? String == "qwen4_exp",
                vision["hidden_act"] as? String == "gelu_pytorch_tanh",
                text["hidden_size"] as? Int == 2560,
                text["num_hidden_layers"] as? Int == 48,
                vision["depth"] as? Int == 27,
                vision["hidden_size"] as? Int == 1152,
                vision["num_heads"] as? Int == 16,
                vision["out_hidden_size"] as? Int == 2560,
                vision["patch_size"] as? Int == 16,
                vision["spatial_merge_size"] as? Int == 2,
                vision["temporal_patch_size"] as? Int == 2,
                let deepstack = vision["deepstack_visual_indexes"] as? [Any], deepstack.isEmpty
            else { return false }
            return true
        }
        guard configuration["language_model_only"] as? Bool != true else { return false }
        return configuration["vision_config"] != nil
    }
}
