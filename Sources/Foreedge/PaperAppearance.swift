import CoreGraphics

enum PaperMode: String, CaseIterable, Identifiable, Codable {
    case plain = "Plain"
    case warm = "Warm"
    case paper = "Paper"
    var id: Self { self }
}

enum PaperExperiment: String, CaseIterable, Identifiable, Codable {
    case original = "Original"
    case balanced = "Balanced"
    case relief = "Soft relief"
    case adaptive = "Adaptive"
    var id: Self { self }

    var detail: String {
        switch self {
        case .original: return "The first treatment. More grain also darkens the page."
        case .balanced: return "Fine grain with a steady average paper tone."
        case .relief: return "The same fibers, with soft light from the upper left."
        case .adaptive: return "Soft relief with quieter grain over dark content."
        }
    }
}

struct PaperAppearance: Equatable, Codable {
    var mode: PaperMode = .paper
    var experiment: PaperExperiment = .balanced
    var warmth: Double = 0.55
    // Reserve a little white headroom for both light and dark texture details.
    var brightness: Double = 0.94
    var grain: Double = 0.45

    var color: CGColor { surfaceColor(texture: nil) }

    func surfaceColor(texture: PaperTexture?) -> CGColor {
        guard mode != .plain else { return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        let amount = min(1, max(0, warmth))
        let tone = experiment == .original ? 1 : min(0.94, max(0.78, brightness))
        let opacity = Double(textureOpacity)
        let compensation: Double
        if experiment != .original, let field = texture?.field(for: experiment) {
            compensation = 1 - opacity + opacity * field.mean
        } else {
            compensation = 1
        }
        return CGColor(srgbRed: min(1, (1 - 0.025 * amount) * tone / compensation),
                       green: min(1, (1 - 0.085 * amount) * tone / compensation),
                       blue: min(1, (1 - 0.20 * amount) * tone / compensation), alpha: 1)
    }

    var textureOpacity: Float {
        mode == .paper ? Float(min(1, max(0, grain))) : 0
    }
}
