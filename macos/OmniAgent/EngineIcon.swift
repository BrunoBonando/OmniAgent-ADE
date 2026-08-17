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

/// The engine badge in a terminal's header — the pill that says which agent is
/// driving this PTY. Colours are lifted from the pane grid in
/// `design/OmniAgent ADE.dc.html`: each engine carries its own brand hue at low
/// alpha, so four panes side by side are told apart by colour before the label
/// is ever read.
extension Engine {
    /// What the badge calls this engine. Claude's CLI is branded "Claude Code",
    /// which is what the design prints — the rest are their own names.
    var badgeTitle: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "AntiGravity"
        case .copilot: return "Copilot"
        case .shell: return "Shell"
        }
    }

    /// What a *terminal* running this engine is called — "Claude 2", "Shell 1".
    /// Deliberately shorter than `badgeTitle`: the header prints the engine
    /// badge right beside the name, and "Claude Code 2 [Claude Code]" says it
    /// twice.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "AntiGravity"
        case .copilot: return "Copilot"
        case .shell: return "Shell"
        }
    }

    var badgeForeground: NSColor {
        switch self {
        case .claude: return srgb(240, 138, 93)
        case .codex: return srgb(162, 231, 249)
        case .antigravity: return srgb(110, 168, 255)
        case .copilot: return srgb(201, 201, 210)
        case .shell: return srgb(154, 156, 166)
        }
    }

    var badgeFill: NSColor {
        switch self {
        case .claude: return srgb(240, 138, 93, 0.14)
        case .codex: return srgb(162, 231, 249, 0.12)
        // The fill is keyed to AntiGravity's own blue (#3186ff), not to the
        // lighter foreground the design uses for its text.
        case .antigravity: return srgb(49, 134, 255, 0.12)
        case .copilot, .shell: return NSColor(white: 1, alpha: 0.055)
        }
    }

    var badgeStroke: NSColor {
        switch self {
        case .claude: return srgb(240, 138, 93, 0.28)
        case .codex: return srgb(162, 231, 249, 0.26)
        case .antigravity: return srgb(49, 134, 255, 0.26)
        case .copilot, .shell: return NSColor(white: 1, alpha: 0.08)
        }
    }

    private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

extension NSImage {
    /// A template image recoloured. Non-template art (the brand logos) is
    /// returned untouched, so one call site can tint the shell/Copilot glyphs
    /// without flattening Claude's or Codex's own palettes.
    func tinted(_ color: NSColor) -> NSImage {
        guard isTemplate else { return self }
        return NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
