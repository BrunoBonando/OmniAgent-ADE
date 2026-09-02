import AppKit
import IOKit

// The flat Copilot-style sidebar — the 2026-08-20 navigation redesign
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md). One
// straight column in the existing `ShellPalette` language: fixed nav rows on
// top (Home, To Do List, Search), then the Workspaces section holding the
// workspaces tree (`WorkspacesTree.swift`), and the account row pinned at the
// bottom. It replaces the two-level sliding track `WorkspaceShell.swift` used
// to build; that file keeps the shared tokens, glyphs and row classes.

// MARK: - Fixed nav rows

/// The sidebar's three fixed rows. Home and To Do List are destinations;
/// Search only acts — it raises the spotlight and selects nothing.
enum SidebarNavItem: CaseIterable {
    case home
    case todo
    case search

    var title: String {
        switch self {
        case .home: return "Home"
        case .todo: return "To Do List"
        case .search: return "Search"
        }
    }

    /// SF Symbols approximating Copilot's set.
    var symbol: String {
        switch self {
        case .home: return "house"
        case .todo: return "checklist"
        case .search: return "magnifyingglass"
        }
    }

    /// Where the row routes, or `nil` for a row that only acts.
    var destination: WorkspaceDestination? {
        switch self {
        case .home: return .home
        case .todo: return .todo
        case .search: return nil
        }
    }
}

/// One fixed nav row: symbol and label, flat and squared.
final class SidebarNavRowView: ShellRowView {
    /// The fixed sidebar row this stands for — `nil` for a row built from a
    /// bare title and symbol, which is what the Settings page's column does.
    let item: SidebarNavItem?

    private let icon = NSImageView()
    private let titleField: NSTextField
    private let selectedFill: NSColor
    private(set) var isSelected = false

    convenience init(item: SidebarNavItem) {
        self.init(title: item.title, symbol: item.symbol, item: item)
    }

    init(
        title: String,
        symbol: String,
        item: SidebarNavItem? = nil,
        selectedFill: NSColor = ShellPalette.accentSoft
    ) {
        self.item = item
        self.selectedFill = selectedFill
        titleField = ShellFont.label(
            title,
            font: ShellFont.ui(13.5, .medium),
            color: ShellPalette.inkNav
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        hoverEnabled = false

        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = ShellPalette.inkNav
        icon.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, titleField] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var titleText: String { titleField.stringValue }

    func apply(selected: Bool) {
        isSelected = selected
        titleField.textColor = selected ? ShellPalette.ink : ShellPalette.inkNav
        icon.contentTintColor = selected ? ShellPalette.ink : ShellPalette.inkNav
        refreshBackground()
        setAccessibilityValue(selected ? "selected" : "")
    }

    override func refreshBackground() {
        let fill: NSColor
        if isSelected {
            fill = selectedFill
        } else if isHovered {
            fill = ShellPalette.hover
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

// MARK: - Section header

/// One of the section header's small icon buttons — an SF Symbol in a
/// 20-point hover square, the same symbol vocabulary as the nav rows above.
final class SidebarHeaderButtonView: ShellRowView {
    /// Which symbol this button wears — a fact for tests, since the image
    /// itself does not answer.
    let symbolName: String

    init(symbol: String, label: String) {
        symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = ShellPalette.chevron
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The "Workspaces" section header: the tracked title on the left, the
/// group-by and plus icon buttons on the right. The buttons only report
/// presses — the sidebar builds the menus and pops them, because the menus
/// read state (the tree's mode, the rendered workspaces) the header never
/// holds.
final class SidebarSectionHeaderView: NSView {
    private let titleField: NSTextField

    let groupButton = SidebarHeaderButtonView(symbol: "rectangle.grid.1x2", label: "Group by")
    let plusButton = SidebarHeaderButtonView(symbol: "plus", label: "Add")

    init(title: String) {
        titleField = ShellFont.label(
            title,
            font: ShellFont.ui(11.5, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 0.5
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [titleField, groupButton, plusButton] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            titleField.trailingAnchor.constraint(
                lessThanOrEqualTo: groupButton.leadingAnchor, constant: -8
            ),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupButton.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -2),
            groupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var title: String { titleField.stringValue }
}

// MARK: - Account row

/// The pinned footer: the signed-in account — its picture, or its initials,
/// or a generic glyph when there is no account at all — beside the gear that
/// opens the app's existing Settings surface. Pressing the account half opens
/// Settings › Accounts; pressing the gear offers the Settings panel.
final class SidebarAccountRowView: NSView {
    var onOpenSettings: (() -> Void)?
    /// The account half was pressed — Settings › Accounts, where the identity
    /// this row shows is managed.
    var onOpenAccount: (() -> Void)?

    /// The chip's own height, and half of it its capsule radius. Fixed rather
    /// than derived from the label's padding because the row is now a card:
    /// the sidebar insets it from its own edges so it clears the window's
    /// corner curve — on macOS 26 that curve is wide enough that an
    /// edge-to-edge footer tucks its avatar under the bevel.
    static let height: CGFloat = 44

    /// What the avatar circle is currently showing. Named for what it is
    /// for: three mutually exclusive layers share the circle, and this is
    /// the one fact about them a test can read without walking the tree.
    enum AvatarMode: Equatable {
        case glyph
        case initials(String)
        case picture
    }

    private let nameField = ShellFont.label(
        "Not signed in",
        font: ShellFont.ui(13.5, .medium),
        color: ShellPalette.inkTertiary
    )

    /// Exposed so a test can press the gear the way a user does.
    private(set) var gear = ShellRowView()
    /// The avatar-and-name half, pressable in its own right — exposed for
    /// the same reason the gear is.
    private(set) var accountButton = ShellRowView()

    private let avatar = NSView()
    private let person = NSImageView()
    private let pictureView = NSImageView()
    private let initialsField = ShellFont.label(
        "",
        font: ShellFont.ui(12, .semibold),
        color: ShellPalette.ink
    )

    /// What the row says about the account — a fact a test can read without
    /// walking the view tree.
    var accountLabel: String { nameField.stringValue }
    private(set) var avatarModeForTesting: AvatarMode = .glyph

    /// The frames the cursor rects were last built from, so `layout()` only
    /// invalidates them when they actually moved.
    private var cursorRectFrames: [NSRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Liquid Glass where there is glass to ask for. Before macOS 26 there
        // is none, and every stand-in dims rather than refracts, so the
        // fallback is the plainest thing that still reads as a card.
        let glass = WorkspaceGlass.sheet(cornerRadius: Self.height / 2)
        if glass == nil {
            layer?.cornerRadius = Self.height / 2
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = ShellMetrics.accountAvatar / 2
        avatar.layer?.backgroundColor = ShellPalette.iconTile.cgColor
        avatar.layer?.borderWidth = 1
        avatar.layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        avatar.translatesAutoresizingMaskIntoConstraints = false
        person.image = NSImage(
            systemSymbolName: "person.fill",
            accessibilityDescription: "Account"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        person.contentTintColor = ShellPalette.inkMuted
        person.translatesAutoresizingMaskIntoConstraints = false
        initialsField.alignment = .center
        initialsField.isHidden = true
        // Clipped by its own layer rather than by the circle's: a
        // `masksToBounds` on the circle would cut into the hairline ring it
        // draws around itself, and that ring is what separates a dark
        // picture from the dark chip behind it.
        pictureView.wantsLayer = true
        pictureView.layer?.cornerRadius = ShellMetrics.accountAvatar / 2
        pictureView.layer?.masksToBounds = true
        pictureView.imageScaling = .scaleAxesIndependently
        pictureView.isHidden = true
        pictureView.translatesAutoresizingMaskIntoConstraints = false
        for view in [person, initialsField, pictureView] { avatar.addSubview(view) }

        accountButton.wantsLayer = true
        accountButton.layer?.cornerRadius = Self.accountButtonHeight / 2
        accountButton.layer?.cornerCurve = .continuous
        accountButton.hoverFill = NSColor(white: 1, alpha: 0.09)
        accountButton.onPress = { [weak self] in self?.onOpenAccount?() }
        accountButton.setAccessibilityLabel("Not signed in")
        accountButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [avatar, nameField] { accountButton.addSubview(view) }

        gear.wantsLayer = true
        gear.layer?.cornerRadius = 6
        gear.hoverFill = NSColor(white: 1, alpha: 0.09)
        gear.onPress = { [weak self] in self?.onOpenSettings?() }
        gear.setAccessibilityLabel("Settings")
        gear.translatesAutoresizingMaskIntoConstraints = false
        // The system gear, not the hand-drawn one this used to carry: a ring
        // with eight straight spokes is the brightness glyph, and at 20pt it
        // read as one.
        let gearGlyph = NSImageView()
        gearGlyph.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        gearGlyph.contentTintColor = ShellPalette.chevron
        gearGlyph.translatesAutoresizingMaskIntoConstraints = false
        gear.addSubview(gearGlyph)

        for view in [glass, accountButton, gear].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            // Inset 4 from the chip's edge so the avatar still sits 11 in,
            // exactly where it sat before the account half became pressable.
            accountButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            accountButton.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -4),
            accountButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            accountButton.heightAnchor.constraint(equalToConstant: Self.accountButtonHeight),

            avatar.leadingAnchor.constraint(equalTo: accountButton.leadingAnchor, constant: 7),
            avatar.centerYAnchor.constraint(equalTo: accountButton.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: ShellMetrics.accountAvatar),
            avatar.heightAnchor.constraint(equalToConstant: ShellMetrics.accountAvatar),
            person.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            person.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            initialsField.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initialsField.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            pictureView.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            pictureView.trailingAnchor.constraint(equalTo: avatar.trailingAnchor),
            pictureView.topAnchor.constraint(equalTo: avatar.topAnchor),
            pictureView.bottomAnchor.constraint(equalTo: avatar.bottomAnchor),

            nameField.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: accountButton.trailingAnchor, constant: -8),
            nameField.centerYAnchor.constraint(equalTo: accountButton.centerYAnchor),

            gear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gear.centerYAnchor.constraint(equalTo: centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: 24),
            gear.heightAnchor.constraint(equalToConstant: 24),
            gearGlyph.centerXAnchor.constraint(equalTo: gear.centerXAnchor),
            gearGlyph.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
        ])
        if let glass {
            glass.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Not signed in")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The pressable half's height — a capsule inside the chip, so its hover
    /// fill reads as part of the card rather than as a second one.
    private static let accountButtonHeight: CGFloat = 32

    /// Who the row is for. `name` nil (or blank) is the signed-out state:
    /// "Not signed in" in the dim tertiary ink, over the generic glyph.
    /// A name gets the sidebar's primary ink and, failing a picture, its own
    /// initials — the picture wins whenever one has arrived.
    func apply(name: String?, picture: NSImage?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let label {
            nameField.stringValue = label
            nameField.textColor = ShellPalette.ink
            // Middle, not tail: the tail of a long name is the surname, and
            // "Bruno Bona…" throws away the half that identifies the account.
            nameField.lineBreakMode = .byTruncatingMiddle
        } else {
            nameField.stringValue = "Not signed in"
            nameField.textColor = ShellPalette.inkTertiary
            nameField.lineBreakMode = .byTruncatingTail
        }
        setAccessibilityLabel(nameField.stringValue)
        accountButton.setAccessibilityLabel(nameField.stringValue)

        if let picture {
            avatarModeForTesting = .picture
        } else if let initials = Self.initials(of: label) {
            avatarModeForTesting = .initials(initials)
        } else {
            avatarModeForTesting = .glyph
        }
        // Three layers share the circle; exactly one of them is on.
        switch avatarModeForTesting {
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

    /// Both halves are buttons, and a button says so under the pointer.
    /// The sidebar is a plain view in a window — no scroll view between it
    /// and the frame — so AppKit rebuilds these whenever the window's cursor
    /// rects are invalidated, which `layout()` below asks for as soon as
    /// either frame moves.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(accountButton.frame, cursor: .pointingHand)
        addCursorRect(gear.frame, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        let frames = [accountButton.frame, gear.frame]
        guard frames != cursorRectFrames else { return }
        cursorRectFrames = frames
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - System stats

/// What the machine is doing right now, read straight from the kernel — no
/// spawned processes, no dependencies. CPU and memory come from Mach host
/// statistics; GPU utilization from the accelerator's IOKit performance
/// dictionary, `nil` where the driver does not publish one.
enum MachineStats {
    /// Busy/total CPU ticks from the previous sample, so the next one can
    /// report the load *since then* rather than since boot.
    /// ponytail: static state — one sidebar samples this; make it per-view if a second ever does.
    private static var lastTicks: (busy: UInt64, total: UInt64)?

    /// Aggregate CPU load across all cores since the previous call, 0...1.
    /// `nil` on the first call (no baseline yet) and on kernel refusal.
    static func cpuFraction() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    /// Memory pressure the way Activity Monitor counts it: active + wired +
    /// compressed pages over physical RAM, 0...1.
    static func memoryFraction() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    /// The busiest accelerator's "Device Utilization %", 0...1, or `nil` when
    /// no driver publishes one.
    static func gpuFraction() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, value / 100)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }
}

/// The one timer that samples [`MachineStats`] — every consumer of the
/// gauges reads *this*, rather than calling `cpuFraction()`/`memoryFraction()`/
/// `gpuFraction()` on its own.
///
/// That is not a style preference: `MachineStats.cpuFraction()` computes a
/// delta against `lastTicks`, one piece of static state shared by every
/// caller. Two independent samplers — the sidebar's own two-second `Timer`
/// and a second one added for remote sharing (spec §4, Task 22) — would each
/// silently overwrite the other's baseline, so *both* readings would be
/// deltas against whichever caller happened to sample most recently rather
/// than against their own last sample. `HostMetricsSource` is what makes that
/// impossible instead of merely unlikely: one timer, one call to each
/// `MachineStats` function per tick, fanned out to every observer.
///
/// Runs only while it has an observer, and stops the moment it has none —
/// the sidebar's dial while its window is on screen, `HostStatePublisher`
/// while the remote lease is held. Neither needing it is a machine with no
/// visible sidebar and no viewer, which must do no work at all.
final class HostMetricsSource {
    static let shared = HostMetricsSource()

    struct Snapshot {
        var cpu: Double?
        var memory: Double?
        var gpu: Double?
    }

    private(set) var latest = Snapshot(cpu: nil, memory: nil, gpu: nil)

    private var observers: [ObjectIdentifier: (Snapshot) -> Void] = [:]
    private var timer: Timer?

    private init() {}

    /// Registers `owner` for every future sample, starting the timer if this
    /// is the first observer. Idempotent per owner, like
    /// `ClaudeUsageLimitsPoller.addObserver`: re-registering replaces that
    /// owner's block and nobody else's.
    func addObserver(_ owner: AnyObject, _ block: @escaping (Snapshot) -> Void) {
        observers[ObjectIdentifier(owner)] = block
        guard timer == nil else { return }
        // A throwaway read establishes `MachineStats`'s delta baseline now,
        // so the first real sample one tick later is a fraction over the
        // second that just elapsed rather than `nil` for want of one.
        _ = MachineStats.cpuFraction()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Unregisters `owner`, stopping the timer once nobody is left watching.
    func removeObserver(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
        guard observers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        latest = Snapshot(
            cpu: MachineStats.cpuFraction(),
            memory: MachineStats.memoryFraction(),
            gpu: MachineStats.gpuFraction()
        )
        for observer in observers.values { observer(latest) }
    }
}

/// One machine stat in the hover card's git-tab language (`HoverGitStatView`):
/// the big number over a small caption. Except there the colour names the
/// column and here it *is* the reading — green while comfortable, amber past
/// 70%, red past 90%.
/// A half-circle dial with a needle: the machine's own readouts, which are a
/// live signal rather than a quota.
///
/// The needle *travels* to a new sample instead of jumping to it. That is the
/// point of a dial over a bar here — these numbers are resampled every two
/// seconds, and a needle sweeping to 60% reads as a machine getting busier,
/// where a bar that redraws at a new length each tick just flickers.
final class SidebarDialGaugeView: NSView {
    /// The cards' shared motion. A needle springs in both directions, unlike
    /// a bar: overshoot past either end of a dial costs nothing — `strokeEnd`
    /// clamps at 1, and a needle swinging a couple of degrees beyond
    /// hard-right for a moment is the behaviour being imitated.
    static var sweepDuration: TimeInterval { SidebarMotion.duration }
    static var sweepCurve: CAMediaTimingFunction { SidebarMotion.overshoot }

    private static let lineWidth: CGFloat = 4
    private static let hubRadius: CGFloat = 3

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let needle = CAShapeLayer()
    private let hub = CAShapeLayer()

    private(set) var fraction: Double?

    static let strokeKey = "om-dial-stroke"
    static let needleKey = "om-dial-needle"

    /// The motion currently attached to the needle, if any.
    var needleAnimation: CABasicAnimation? {
        needle.animation(forKey: Self.needleKey) as? CABasicAnimation
    }

    /// What the needle is pointing at, in turns of the dial: 0 hard left, 1
    /// hard right.
    ///
    /// This is the value that went *in*. It says nothing about where the
    /// needle actually points — a sign error in the rotation left this reading
    /// 0.11 while the needle sat past vertical on the right. Use `needleTip`
    /// for that.
    var needleFraction: Double { fraction ?? 0 }

    /// The rotation applied to the needle for `fraction`, counterclockwise
    /// from straight up.
    ///
    /// Half a turn each way: hard left at 0, up at a half, hard right at 1.
    /// The needle is drawn pointing up, and positive z-rotation is
    /// counterclockwise in this view's unflipped geometry — so the angle
    /// *decreases* as the dial fills. Getting that sign backwards is what put
    /// the needle on the wrong side of the dial.
    static func rotation(for fraction: Double) -> CGFloat {
        (0.5 - CGFloat(min(max(fraction, 0), 1))) * .pi
    }

    /// Which way the needle points, as a unit vector in this view's space.
    ///
    /// Derived the same way the layer's own transform is, so it moves with the
    /// needle rather than describing it from memory: rotating the up vector
    /// `(0, 1)` by `rotation(for:)` gives `(-sin θ, cos θ)`.
    static func needleDirection(for fraction: Double) -> NSPoint {
        let angle = rotation(for: fraction)
        return NSPoint(x: -sin(angle), y: cos(angle))
    }

    /// Where on the arc `fraction` falls, as a unit vector — the needle's own
    /// direction is supposed to equal this, and a test says so.
    ///
    /// The arc is swept from `π` to `0`, so the angle runs backwards as the
    /// dial fills.
    static func arcDirection(for fraction: Double) -> NSPoint {
        let angle = (1 - CGFloat(min(max(fraction, 0), 1))) * .pi
        return NSPoint(x: cos(angle), y: sin(angle))
    }
    var progressColor: NSColor? {
        progress.strokeColor.map { NSColor(cgColor: $0) ?? .clear }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for arc in [track, progress] {
            arc.fillColor = nil
            arc.lineWidth = Self.lineWidth
            arc.lineCap = .round
            layer?.addSublayer(arc)
        }
        track.strokeColor = NSColor(white: 1, alpha: 0.10).cgColor
        progress.strokeColor = ShellPalette.green.cgColor
        progress.strokeEnd = 0
        needle.strokeColor = ShellPalette.ink.cgColor
        needle.lineWidth = 2
        needle.lineCap = .round
        hub.fillColor = ShellPalette.ink.cgColor
        for part in [needle, hub] { layer?.addSublayer(part) }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Tall enough for the arc and its stroke, given the width it gets. The
    /// half below the diameter is empty by definition, so the dial claims
    /// none of it and the number sits there instead.
    static func height(forWidth width: CGFloat) -> CGFloat {
        radius(forWidth: width) + lineWidth / 2 + hubRadius
    }

    private static func radius(forWidth width: CGFloat) -> CGFloat {
        max((width - lineWidth) / 2, 1)
    }

    func apply(_ value: Double?, animated: Bool = true) {
        fraction = value.map { min(max($0, 0), 1) }
        setArcColour(for: fraction)
        // Explicit, for the same reason the bars are: an implicit animation is
        // an action, and actions are suppressed wherever AppKit has disabled
        // them. Filed under known keys so a test can see the motion was set up
        // without a presentation layer that advances.
        let target = CGFloat(fraction ?? 0)
        SidebarMotion.move(
            progress, "strokeEnd", to: target,
            from: progress.presentation()?.strokeEnd ?? progress.strokeEnd,
            animated: animated, rising: true, bothWays: true, key: Self.strokeKey
        )
        SidebarMotion.move(
            needle, "transform",
            to: NSValue(caTransform3D: CATransform3DMakeRotation(Self.rotation(for: target), 0, 0, 1)),
            from: (needle.presentation() ?? needle)?.value(forKeyPath: "transform"),
            animated: animated, rising: true, bothWays: true, key: Self.needleKey
        )
        setAccessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "no reading")
    }

    /// Repaints the arc without touching the needle or its sweep, so the
    /// colour can be walked through the ramp frame by frame while the needle
    /// travels — see `SidebarPercentBarView.setFillColour`.
    func setArcColour(for value: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeColor = SidebarPercentBarView.colour(for: value).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let radius = min(
            Self.radius(forWidth: bounds.width),
            bounds.height - Self.lineWidth / 2 - Self.hubRadius
        )
        // The hub sits on the diameter, which is this view's own bottom edge
        // less the room the hub itself needs.
        let centre = NSPoint(x: bounds.midX, y: Self.hubRadius)
        let arc = CGMutablePath()
        arc.addArc(
            center: centre, radius: radius,
            startAngle: .pi, endAngle: 0, clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, progress] {
            layer.frame = bounds
            layer.path = arc
        }
        let stem = CGMutablePath()
        stem.move(to: NSPoint(x: 0, y: 0))
        stem.addLine(to: NSPoint(x: 0, y: radius - Self.lineWidth - 2))
        needle.path = stem
        // Positioned rather than framed, so the rotation in `apply` turns the
        // needle about the hub instead of about a corner.
        needle.bounds = NSRect(x: 0, y: 0, width: 0, height: radius)
        needle.position = centre
        needle.anchorPoint = NSPoint(x: 0.5, y: 0)
        hub.path = CGPath(
            ellipseIn: NSRect(
                x: centre.x - Self.hubRadius, y: centre.y - Self.hubRadius,
                width: Self.hubRadius * 2, height: Self.hubRadius * 2
            ),
            transform: nil
        )
        CATransaction.commit()
    }
}

final class SidebarStatGaugeView: NSView {
    private let valueField: NSTextField
    private let captionField: NSTextField
    /// Counts the percentage through every value between two samples, at the
    /// pace of the needle beside it.
    private var counter: SidebarCountingLabel!
    /// A dial rather than the Claude card's bar.
    ///
    /// These three are a live signal resampled every two seconds, not a quota
    /// filling up once: a needle that travels reads as a machine getting
    /// busier, where a bar redrawn at a new length each tick only flickers.
    /// The colour ramp is still shared, so the two cards disagree about the
    /// shape and about nothing else.
    let dial = SidebarDialGaugeView()
    private(set) var fraction: Double?

    /// What the gauge currently reads — a fact a test can assert without
    /// rendering. "—" until a sample lands, or when the metric never will.
    var readout: String { valueField.stringValue }
    /// The pressure verdict the number wears.
    var readoutColor: NSColor? { valueField.textColor }

    init(name: String) {
        valueField = ShellFont.label(
            "—",
            font: ShellFont.ui(18, .semibold),
            color: ShellPalette.inkTertiary
        )
        captionField = ShellFont.label(
            name,
            font: ShellFont.ui(10, .semibold),
            color: ShellPalette.inkTertiary,
            tracking: 0.5
        )
        super.init(frame: .zero)
        counter = SidebarCountingLabel { [weak self] value in
            guard let self else { return }
            self.valueField.stringValue = "\(Int(value.rounded()))%"
            // The colour walks the ramp with the number, so a gauge crossing
            // into amber does it gradually rather than in one step.
            let reached = value / 100
            self.valueField.textColor = SidebarPercentBarView.colour(for: reached)
            self.dial.setArcColour(for: reached)
        }
        translatesAutoresizingMaskIntoConstraints = false
        valueField.alignment = .center
        captionField.alignment = .center

        // Caption, dial, then the number under the arc it belongs to — the
        // arrangement of the reference gauges, and the label still names the
        // thing before the number answers it.
        let stack = NSStackView(views: [captionField, dial, valueField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Full width rather than hugging its labels: the bar spans the
            // column, and a stack sized to the widest label would cut it to
            // the width of the word "MEM".
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            dial.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dial.heightAnchor.constraint(equalToConstant: Self.dialHeight),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// How much of the column the arc gets. Authored rather than derived from
    /// the width, because the width is only known after layout and a dial that
    /// resizes the card as the sidebar is dragged is worse than a slightly
    /// small arc.
    static let dialHeight: CGFloat = 26

    func apply(_ value: Double?, animated: Bool = true) {
        fraction = value.map { min(max($0, 0), 1) }
        dial.apply(fraction, animated: animated)
        if let fraction {
            counter.count(to: fraction * 100, animated: animated)
        } else {
            // No sample is the absence of a number, not a journey to zero.
            counter.settle(at: 0)
            valueField.stringValue = "—"
        }
        if fraction == nil {
            // The count paints the number while it travels; with no sample to
            // travel to, the colour has to be set here instead. Through the
            // bar's own ramp either way, rather than a second copy of the same
            // thresholds, so a number and its dial cannot drift apart.
            valueField.textColor = SidebarPercentBarView.colour(for: nil)
        }
        setAccessibilityValue(valueField.stringValue)
    }

    /// What the number is counting, for a test that would otherwise have to
    /// wait out an animation to see it.
    var countingLabel: SidebarCountingLabel { counter }
}

/// The machine gauges pinned just above the account row: CPU, memory and GPU
/// side by side in the hover card's three-numbers arrangement — equal-width
/// columns split by hairlines — resampled once a second, through
/// [`HostMetricsSource`], while the sidebar is on screen.
final class SidebarSystemStatsView: NSView {
    static let height: CGFloat = 76

    let cpuGauge = SidebarStatGaugeView(name: "CPU")
    let memoryGauge = SidebarStatGaugeView(name: "MEM")
    let gpuGauge = SidebarStatGaugeView(name: "GPU")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // The account row's exact glass treatment, one radius shy of its
        // capsule — this card is taller than a chip.
        let glass = WorkspaceGlass.sheet(cornerRadius: 14)
        if glass == nil {
            layer?.cornerRadius = 14
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        let stack = NSStackView(views: [
            cpuGauge, Self.divider(), memoryGauge, Self.divider(), gpuGauge,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        memoryGauge.widthAnchor.constraint(equalTo: cpuGauge.widthAnchor).isActive = true
        gpuGauge.widthAnchor.constraint(equalTo: cpuGauge.widthAnchor).isActive = true

        for view in [glass, stack].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let glass {
            glass.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("System stats")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Watches [`HostMetricsSource`] only while there is a window to show
    /// readings in — unregistering, not merely ignoring what arrives, so a
    /// sidebar with no window is one fewer reason for the shared timer to
    /// keep running at all.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HostMetricsSource.shared.removeObserver(self)
        guard window != nil else { return }
        HostMetricsSource.shared.addObserver(self) { [weak self] snapshot in
            self?.apply(cpu: snapshot.cpu, memory: snapshot.memory, gpu: snapshot.gpu)
        }
    }

    /// Split from the `HostMetricsSource` callback so a test can feed
    /// fractions without a kernel.
    func apply(cpu: Double?, memory: Double?, gpu: Double?, animated: Bool = true) {
        cpuGauge.apply(cpu, animated: animated)
        memoryGauge.apply(memory, animated: animated)
        gpuGauge.apply(gpu, animated: animated)
    }

    /// The hairline between two stats — the git tab's divider, a touch
    /// shorter for this card's height.
    private static func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 26),
        ])
        return view
    }
}

// MARK: - The sidebar


/// The sidebar itself: one flat column, top to bottom — nav rows, the
/// Workspaces section with the workspaces tree, the account row.
final class NavigationSidebarView: NSView {
    /// Home or To Do List was pressed (Search never routes here).
    var onSelectDestination: ((WorkspaceDestination) -> Void)?
    /// The Search row: raise the spotlight. Deliberately not a selection —
    /// the lit row stays wherever it was.
    var onSearch: (() -> Void)?
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    /// The workspaces tree's hovers, forwarded to the controller — which owns
    /// the hover card, because the card is a window and the sidebar is a view.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The account chip's own half, as opposed to its gear: Settings ›
    /// Accounts, where the identity the chip shows is managed.
    var onOpenAccount: (() -> Void)?
    /// The plus menu's "Start session in" — a workspace id; the controller
    /// resolves it to a directory and starts the session there.
    var onStartSession: ((String) -> Void)?
    /// The plus menu's "Local folder or repository…" — the existing
    /// add-workspace folder chooser.
    var onAddLocalFolder: (() -> Void)?
    /// A workspace row's right-click, forwarded to the controller — which
    /// resolves the workspace's directory, GitHub remote and stored
    /// customization, none of which the sidebar holds.
    var workspaceMenuProvider: ((String) -> NSMenu?)?
    /// A session row's right-click, same contract: the pin state, the
    /// installed apps and the delete path all live on the controller.
    var sessionMenuProvider: ((SessionGroupNode) -> NSMenu?)?
    /// A remote machine's session row was clicked — device id, session id,
    /// title — forwarded to the controller, which owns the remote panes.
    var onOpenRemoteSession: ((String, String, String) -> Void)?
    /// The plus menu's "Resume remote session…" — the controller opens the
    /// picker of the other Macs' shared sessions
    /// (`RemoteSessionPickerController`).
    var onResumeRemoteSession: (() -> Void)?
    /// A workspace row's viewer count was pressed — the controller opens the
    /// list of machines watching it (the phase 2 spec's §5). Same contract as
    /// `workspaceMenuProvider`: the roster lives on the controller.
    var onShowViewers: ((String) -> Void)?

    private(set) var navRows: [SidebarNavRowView] = []
    /// The self-update card, directly above the session/week limits card —
    /// same glass, same radius, same inset, hidden until there is an update to
    /// talk about (`SidebarUpdateWidget.swift`).
    let updateWidget = SidebarUpdateWidgetView()
    let workspacesHeader = SidebarSectionHeaderView(title: "Workspaces")
    let workspacesTree = WorkspacesTreeView()
    let claudeLimits = SidebarClaudeLimitsView()
    let statsRow = SidebarSystemStatsView()
    let accountRow = SidebarAccountRowView()
    private(set) var destination: WorkspaceDestination = .home

    /// The column's ground on macOS 26: one full-bleed sheet of Liquid Glass
    /// behind every row, with `glassTint` washing the design's blue over it.
    /// `nil` below 26, where `draw` paints the opaque gradient instead.
    ///
    /// Full-bleed and square — no inset, no corner radius. The rim the sheet
    /// draws down its trailing edge is the border between the column and the
    /// black pane area, which is the whole reason for the glass. An inset
    /// rounded slab is the chrome a `.sidebar` split item gives for free, and
    /// the one this app turned down (see `installSplitView`).
    private(set) var glassHost: NSView?
    /// The blue over the sheet — the glass view's `contentView`, so it is
    /// composited on top of the material rather than behind it.
    private(set) var glassTint: NSView?
    /// The grey line where the column stops. Topmost, so nothing the column
    /// grows later can cover the one thing that separates it from the panes.
    let trailingEdge = NSView()
    /// What the plus menu lists: every workspace the tree currently renders,
    /// in render order.
    private(set) var workspaceMenuEntries: [(id: String, label: String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        navRows = SidebarNavItem.allCases.map { item in
            let row = SidebarNavRowView(item: item)
            row.onPress = { [weak self] in
                guard let self else { return }
                if let destination = item.destination {
                    applyDestination(destination)
                    onSelectDestination?(destination)
                } else {
                    onSearch?()
                }
            }
            return row
        }

        let navStack = NSStackView(views: navRows)
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 0, right: 8)
        navStack.translatesAutoresizingMaskIntoConstraints = false
        for row in navRows {
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -16).isActive = true
        }

        let scroll = ShellScrollView(documentView: workspacesTree)

        accountRow.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        accountRow.onOpenAccount = { [weak self] in self?.onOpenAccount?() }
        workspacesHeader.groupButton.onPress = { [weak self] in
            guard let self else { return }
            pop(makeGroupByMenu(), from: workspacesHeader.groupButton)
        }
        workspacesHeader.plusButton.onPress = { [weak self] in
            guard let self else { return }
            pop(makePlusMenu(), from: workspacesHeader.plusButton)
        }
        workspacesTree.onSelectSession = { [weak self] session in self?.onSelectSession?(session) }
        workspacesTree.onRenameSession = { [weak self] session, name in
            self?.onRenameSession?(session, name)
        }
        workspacesTree.onHoverTarget = { [weak self] target in self?.onHoverTarget?(target) }
        workspacesTree.workspaceMenuProvider = { [weak self] id in self?.workspaceMenuProvider?(id) }
        workspacesTree.sessionMenuProvider = { [weak self] session in
            self?.sessionMenuProvider?(session)
        }
        workspacesTree.onOpenRemoteSession = { [weak self] deviceID, sessionID, title in
            self?.onOpenRemoteSession?(deviceID, sessionID, title)
        }
        workspacesTree.onShowViewers = { [weak self] id in self?.onShowViewers?(id) }

        // The ground first, so every row above sits on it. Sized in `layout`
        // rather than by an autoresizing mask: the mask scales from this
        // view's own frame, which at init is whatever the caller passed —
        // usually zero, and zero scales to zero.
        let tint = ShellGlassTintView()
        if let glass = WorkspaceGlass.sheet(content: tint) {
            glassHost = glass
            glassTint = tint
            addSubview(glass)
        }

        // The update card and the limits card are one stack of cards at the
        // foot of the column, and the stack is what makes hiding the update
        // one work: NSStackView drops a hidden arranged subview from the
        // layout, where a pinned view would keep its height constraint and
        // leave a gap above the gauges.
        updateWidget.isHidden = true
        let bottomCards = NSStackView(views: [updateWidget, claudeLimits])
        bottomCards.orientation = .vertical
        bottomCards.alignment = .leading
        bottomCards.spacing = 8
        bottomCards.translatesAutoresizingMaskIntoConstraints = false
        for card in [updateWidget, claudeLimits] {
            card.widthAnchor.constraint(equalTo: bottomCards.widthAnchor).isActive = true
        }

        for view in [navStack, workspacesHeader, scroll, bottomCards, statsRow, accountRow] {
            addSubview(view)
        }

        // Last, and so on top of everything: the rows are all inset from this
        // edge, so it never covers one, and being topmost means it cannot be
        // covered either.
        trailingEdge.wantsLayer = true
        trailingEdge.layer?.backgroundColor = ShellPalette.sidebarEdge.cgColor
        trailingEdge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingEdge)

        NSLayoutConstraint.activate([
            trailingEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingEdge.topAnchor.constraint(equalTo: topAnchor),
            trailingEdge.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingEdge.widthAnchor.constraint(equalToConstant: 1),
        ])

        NSLayoutConstraint.activate([
            // The column runs under the window chrome (titleBar) and this clears it.
            navStack.topAnchor.constraint(equalTo: topAnchor, constant: WorkspaceTitleBarView.height),
            navStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            workspacesHeader.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 14),
            workspacesHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            workspacesHeader.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: workspacesHeader.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomCards.topAnchor, constant: -8),

            bottomCards.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bottomCards.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bottomCards.bottomAnchor.constraint(equalTo: statsRow.topAnchor, constant: -8),

            statsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statsRow.bottomAnchor.constraint(equalTo: accountRow.topAnchor, constant: -8),

            accountRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            accountRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accountRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        applyDestination(.home)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The sheet fills the column, and so does the wash on it — through every
    /// divider drag, which is the one thing this view's geometry ever does.
    override func layout() {
        super.layout()
        glassHost?.frame = bounds
        glassTint?.frame = NSRect(origin: .zero, size: bounds.size)
    }

    /// Top-lit, so the column has a light source and the content black beside
    /// it does not.
    ///
    /// Only below macOS 26. With glass there is a sheet covering these exact
    /// bounds carrying the same blue itself, and painting an opaque gradient
    /// under it is work no pixel ever shows.
    override func draw(_ dirtyRect: NSRect) {
        guard glassHost == nil else { return }
        ShellPalette.sidebarGlass.draw(in: bounds, angle: -90)
    }

    /// Lights the row for `destination`, or none: Desk (`.terminals`) has no
    /// sidebar row any more — its content is entered through the sessions
    /// tree, the menu and the palette.
    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        for row in navRows { row.apply(selected: row.item?.destination == destination) }
    }

    /// Everything the Workspaces section renders: EVERY workspace, its
    /// sessions inline — never scoped to the open one. The brain's project
    /// list supplies the rows (so a workspace with nothing running still
    /// shows), and the pane descriptors supply the sessions — plus a row for
    /// any project only the panes know about (a folder opened directly).
    func reloadWorkspaces(
        workspaces: [BrainProjectSummary],
        panes: [PaneDescriptor],
        focusedPaneID: String?,
        statuses: [String: RemoteSessionStatus],
        projectLabels: [String: String],
        eventTimes: [String: Double] = [:],
        customizations: [String: WorkspaceCustomization] = [:],
        sessionMeta: [String: SessionMeta] = [:],
        remoteMachines: [RemoteMachineTreeEntry] = [],
        /// Which machines are watching each workspace right now, workspace
        /// id -> machine names (the phase 2 spec's §5). Empty for all but the
        /// rare shared workspace with a viewer on it.
        remoteViewerNames: [String: [String]] = [:]
    ) {
        let grouped = SessionOutline.group(panes, focusedPaneID: focusedPaneID)
        var entries: [WorkspaceTreeEntry] = []
        var listed = Set<String>()
        for workspace in workspaces {
            listed.insert(workspace.id)
            let custom = customizations[workspace.id]
            entries.append(
                WorkspaceTreeEntry(
                    id: workspace.id,
                    label: custom?.displayName ?? workspace.label,
                    sessions: grouped.first { $0.project == workspace.id }?.sessions ?? [],
                    tint: custom?.color?.tint,
                    viewerNames: remoteViewerNames[workspace.id] ?? []
                )
            )
        }
        for node in grouped where !listed.contains(node.project) {
            let custom = customizations[node.project]
            entries.append(
                WorkspaceTreeEntry(
                    id: node.project,
                    label: custom?.displayName
                        ?? SessionOutline.projectLabel(node.project, labels: projectLabels),
                    sessions: node.sessions,
                    tint: custom?.color?.tint,
                    viewerNames: remoteViewerNames[node.project] ?? []
                )
            )
        }
        workspaceMenuEntries = entries.map { ($0.id, $0.label) }
        workspacesTree.reload(
            entries: entries,
            focusedPaneID: focusedPaneID,
            statuses: statuses,
            eventTimes: eventTimes,
            meta: sessionMeta,
            remoteMachines: remoteMachines
        )
    }

    // MARK: - The header's menus

    /// The group-by menu, built fresh per pop so the checkmark always reads
    /// the tree's current mode. Selecting a mode re-renders the tree on the
    /// spot and persists the choice.
    func makeGroupByMenu() -> NSMenu {
        WorkspacesHeaderMenus.groupBy(current: workspacesTree.groupMode) { [weak self] mode in
            self?.workspacesTree.setGroupMode(mode)
        }
    }

    /// The plus menu over whatever the tree currently renders.
    func makePlusMenu() -> NSMenu {
        WorkspacesHeaderMenus.plus(
            workspaces: workspaceMenuEntries,
            startSession: { [weak self] id in self?.onStartSession?(id) },
            addLocalFolder: { [weak self] in self?.onAddLocalFolder?() },
            resumeRemoteSession: { [weak self] in self?.onResumeRemoteSession?() }
        )
    }

    /// Drops the menu just under its button, left-aligned with it.
    private func pop(_ menu: NSMenu, from button: NSView) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 6),
            in: button
        )
    }

    /// Where a hovered row sits on screen right now, or `nil` if it is gone.
    /// The hover card asks this every tick rather than remembering a frame:
    /// the rows are rebuilt constantly.
    func rowFrameOnScreen(for target: SessionHoverCardController.Target) -> NSRect? {
        guard let row = workspacesTree.rowView(for: target),
              let window = row.window,
              row.superview != nil,
              !row.isHiddenOrHasHiddenAncestor,
              row.bounds.width > 0
        else { return nil }
        return window.convertToScreen(row.convert(row.bounds, to: nil))
    }
}
