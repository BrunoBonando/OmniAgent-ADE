import AppKit

// The frame every page destination wears — the 2026-09-01 flow-layout
// design's §5 (`docs/superpowers/specs/2026-09-01-flow-layout-design.md`):
// an H1 title top-left, an optional underline tab strip, a hairline rule,
// then a scrolling card grid. Home and the new Insights page each build
// their content as `body` and hand it to `PageShellView`; the frame itself
// carries no page-specific knowledge.

/// Title → optional tabs → hairline rule → scrolling body, in the existing
/// dark `ShellPalette`/`ShellFont` language. Every page destination's own
/// view is built from this rather than reimplementing the header.
final class PageShellView: NSView {
    let titleField: NSTextField
    /// One row per tab, in `tabs` order — reused `ShellRowView`s, so each
    /// already owns hover tracking, the button accessibility role, and
    /// keyboard activation; this view only wires `onPress` and paints the
    /// label colour and underline.
    private(set) var tabButtons: [ShellRowView] = []
    private(set) var selectedTab = 0
    var onSelectTab: ((Int) -> Void)?
    /// A page-level action view, trailing-aligned with the title. Setting it
    /// swaps out whatever was there before.
    var trailingAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let trailingAccessory else { return }
            trailingAccessory.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(trailingAccessory)
            NSLayoutConstraint.activate([
                trailingAccessory.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -40),
                trailingAccessory.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            ])
        }
    }
    /// Hosts `body`, edge to edge under the header — no fade, no inset; the
    /// header is the page's own boundary now.
    let scroll: ShellScrollView
    /// 2pt, `ShellPalette.ink`, under the selected tab. A test seam as much
    /// as a control: its frame is how a test confirms a press moved it. It
    /// joins the header only when there *are* tabs — on a tabless page it
    /// stays superview-less rather than sitting there unconstrained.
    let underline = NSView()
    /// The title/tabs/rule block, pinned to the shell's own top edge and
    /// spanning its full width — `trailingAccessory` and the hairline rule
    /// are both positioned relative to it, not to individual tab frames.
    let header = NSView()

    private var tabLabels: [NSTextField] = []
    private var underlineLeading: NSLayoutConstraint?
    private var underlineWidth: NSLayoutConstraint?

    init(title: String, tabs: [String] = [], body: NSView) {
        titleField = ShellFont.label(title, font: ShellFont.ui(24, .semibold), color: ShellPalette.ink)
        scroll = ShellScrollView(documentView: body)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scroll)
        header.addSubview(titleField)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),

            titleField.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 40),
            titleField.topAnchor.constraint(equalTo: header.topAnchor, constant: 32),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])

        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.wantsLayer = true
        underline.layer?.backgroundColor = ShellPalette.ink.cgColor

        let rule = ShellSeparator()
        header.addSubview(rule)

        if tabs.isEmpty {
            NSLayoutConstraint.activate([
                rule.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 40),
                rule.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -40),
                rule.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 16),
                header.bottomAnchor.constraint(equalTo: rule.bottomAnchor),
            ])
        } else {
            // The underline belongs to the strip, so it is only added when
            // there is a strip: a tabless page that adopted it got an
            // unconstrained subview — ambiguous layout, and a stray view in
            // the tree — for a mark it would never draw.
            header.addSubview(underline)
            // Rows go straight into `header` — not an `NSStackView` — so a
            // tab's frame and `underline`'s share one coordinate space. The
            // underline is pinned to the selected row's own leading/width
            // anchors (see `select(tab:)`), which only lines up if both live
            // in the same superview.
            var previous: ShellRowView?
            for title in tabs {
                let row = ShellRowView()
                row.hoverEnabled = false
                row.translatesAutoresizingMaskIntoConstraints = false
                let label = ShellFont.label(title, font: ShellFont.ui(14, .medium), color: ShellPalette.inkTertiary)
                row.addSubview(label)
                header.addSubview(row)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    label.topAnchor.constraint(equalTo: row.topAnchor),
                    label.bottomAnchor.constraint(equalTo: row.bottomAnchor),

                    row.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 14),
                ])
                if let previous {
                    row.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 24).isActive = true
                } else {
                    row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 40).isActive = true
                }
                row.setAccessibilityLabel(title)
                let index = tabButtons.count
                row.onPress = { [weak self] in
                    self?.select(tab: index)
                    self?.onSelectTab?(index)
                }
                tabButtons.append(row)
                tabLabels.append(label)
                previous = row
            }

            // Every label shares one font, so any row's bottom is the strip's
            // bottom — `tabButtons[0]` stands in for "the strip" here.
            NSLayoutConstraint.activate([
                underline.heightAnchor.constraint(equalToConstant: 2),
                underline.topAnchor.constraint(equalTo: tabButtons[0].bottomAnchor, constant: 8),

                rule.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 40),
                rule.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -40),
                rule.topAnchor.constraint(equalTo: underline.bottomAnchor),
                header.bottomAnchor.constraint(equalTo: rule.bottomAnchor),
            ])
            select(tab: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Moves the underline to `tab` and restyles the labels. Fires nothing —
    /// `onSelectTab` is only for a press (see the `onPress` closure above).
    func select(tab index: Int) {
        guard tabButtons.indices.contains(index) else { return }
        selectedTab = index
        for (i, label) in tabLabels.enumerated() {
            label.textColor = i == index ? ShellPalette.ink : ShellPalette.inkTertiary
        }
        if let underlineLeading { underlineLeading.isActive = false }
        if let underlineWidth { underlineWidth.isActive = false }
        let tab = tabButtons[index]
        let leading = underline.leadingAnchor.constraint(equalTo: tab.leadingAnchor)
        let width = underline.widthAnchor.constraint(equalTo: tab.widthAnchor)
        NSLayoutConstraint.activate([leading, width])
        underlineLeading = leading
        underlineWidth = width
    }
}
