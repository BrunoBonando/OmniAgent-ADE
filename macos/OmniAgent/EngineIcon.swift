import AppKit

// The design's per-engine logos and the OmniAgent status mark, resolved from
// `Assets.xcassets`. `NSImage(named:)` caches per name, so this is a plain
// lookup with no caching layer of its own.

extension Engine {
    /// The design's per-engine logo, or nil when the asset is missing.
    var iconImage: NSImage? {
        let image = NSImage(named: assetName)
        // Shell and Copilot both ship as near-black art (a stroked outline and
        // a solid `fill="#000000"` mark), which is invisible on this UI, so
        // they are templates the caller tints. Claude, Codex and AntiGravity
        // are colour brand marks and must keep their own palettes.
        image?.isTemplate = (self == .shell || self == .copilot)
        return image
    }

    private var assetName: String {
        switch self {
        case .claude: return "EngineClaude"
        case .codex: return "EngineCodex"
        case .shell: return "EngineShell"
        case .copilot: return "EngineCopilot"
        case .antigravity: return "EngineAntigravity"
        }
    }
}

/// The OmniAgent glyph used for the status mark. Always a template image —
/// the design tints it per status.
enum OmniAgentMark {
    static var image: NSImage? {
        let image = NSImage(named: "OmniAgentMark")
        image?.isTemplate = true
        return image
    }
}
