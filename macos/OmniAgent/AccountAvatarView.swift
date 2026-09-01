import AppKit

/// The signed-in account's circle: its picture, or its initials, or a
/// generic glyph when there is no account at all.
///
/// The app's one avatar circle, worn by the title bar's account button
/// (`TitleBarAccountButton`) — the flow layout's §1 and §3 moved the account
/// out of the sidebar's foot and up into the bar, and this is where the three
/// modes live. The layers are stacked rather than swapped so nothing is
/// rebuilt on a re-`apply`, and `mode` names which of them is on.
final class AccountAvatarView: NSView {
    /// What the circle is currently showing. Named for what it is for:
    /// three mutually exclusive layers share the circle, and this is the one
    /// fact about them a test can read without walking the tree.
    enum AvatarMode: Equatable {
        case glyph
        case initials(String)
        case picture
    }

    private(set) var mode: AvatarMode = .glyph

    private let person = NSImageView()
    private let pictureView = NSImageView()
    private let initialsField: NSTextField

    init(diameter: CGFloat) {
        // The glyph and the initials are sized off the circle rather than
        // pinned at the sidebar's numbers, so the title bar's copy — and any
        // later one — reads at its own diameter instead of rattling inside it.
        initialsField = ShellFont.label(
            "",
            font: ShellFont.ui(diameter * 12 / 22, .semibold),
            color: ShellPalette.ink
        )
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = diameter / 2
        layer?.backgroundColor = ShellPalette.iconTile.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.hairlineStrong.cgColor

        person.image = NSImage(
            systemSymbolName: "person.fill",
            accessibilityDescription: "Account"
        )?.withSymbolConfiguration(.init(pointSize: diameter * 10 / 22, weight: .medium))
        person.contentTintColor = ShellPalette.inkMuted
        person.translatesAutoresizingMaskIntoConstraints = false
        initialsField.alignment = .center
        initialsField.isHidden = true
        // Clipped by its own layer rather than by the circle's: a
        // `masksToBounds` here would cut into the hairline ring the circle
        // draws around itself, and that ring is what separates a dark
        // picture from the dark surface behind it.
        pictureView.wantsLayer = true
        pictureView.layer?.cornerRadius = diameter / 2
        pictureView.layer?.masksToBounds = true
        pictureView.imageScaling = .scaleAxesIndependently
        pictureView.isHidden = true
        pictureView.translatesAutoresizingMaskIntoConstraints = false
        for view in [person, initialsField, pictureView] { addSubview(view) }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            person.centerXAnchor.constraint(equalTo: centerXAnchor),
            person.centerYAnchor.constraint(equalTo: centerYAnchor),
            initialsField.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsField.centerYAnchor.constraint(equalTo: centerYAnchor),
            pictureView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pictureView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pictureView.topAnchor.constraint(equalTo: topAnchor),
            pictureView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Who the circle is for. A picture wins whenever one has arrived; a bare
    /// name falls back to its own initials; nothing at all — the signed-out
    /// state — is the generic glyph.
    func apply(name: String?, picture: NSImage?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if picture != nil {
            mode = .picture
        } else if let initials = Self.initials(of: label) {
            mode = .initials(initials)
        } else {
            mode = .glyph
        }
        // Three layers share the circle; exactly one of them is on.
        switch mode {
        case .glyph:
            (person.isHidden, initialsField.isHidden, pictureView.isHidden) = (false, true, true)
            pictureView.image = nil
        case let .initials(initials):
            initialsField.stringValue = initials
            (person.isHidden, initialsField.isHidden, pictureView.isHidden) = (true, false, true)
            pictureView.image = nil
        case .picture:
            pictureView.image = picture
            (person.isHidden, initialsField.isHidden, pictureView.isHidden) = (true, true, false)
        }
    }

    /// The first letters of the first two words, uppercased — `nil` when
    /// there is no name to take them from.
    private static func initials(of name: String?) -> String? {
        guard let name else { return nil }
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}
