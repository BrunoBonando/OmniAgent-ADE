# App View Chat Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the App view from a readable transcript into a chat: its own ground, ChatGPT's layout with speaker grouping, machinery folded into collapsible chips, and a live per-conversation cost readout.

**Architecture:** Four pure layers with no AppKit dependency (system-block parsing, `/usage` parsing, per-conversation token sums, avatar-run grouping) feeding three view layers (message rows with avatars and bubbles, the stats bar, the composer). `PaneAppView.swift` is already 1605 lines, so new work lands in new files; only `PaneAppMessageRowView`/`PaneAppWorkGroupView` move, because Task 2 rewrites them anyway.

**Tech Stack:** Swift, AppKit (`NSStackView`, `NSTextField`, `NSVisualEffectView`, `CAGradientLayer`, `NSGlassEffectView` via `WorkspaceGlass`), `Process` for the `/usage` fetch, XCTest. Xcode-only build; no Rust toolchain.

**Spec:** `docs/superpowers/specs/2026-08-25-app-view-chat-redesign-design.md` — read it first; where this plan and the spec disagree, the spec wins.

## Global Constraints

- **Native AppKit only.** The `WKWebView` exception in `CLAUDE.md` covers the editor pane's internals and nothing else.
- **New files ARE allowed this time** and must be added to `macos/OmniAgent.xcodeproj/project.pbxproj`. Before staging that file, run `git status --porcelain macos/OmniAgent.xcodeproj/project.pbxproj` — if another session has dirtied it, stop and report rather than staging their changes.
- **`ClaudeTranscriptReader`'s parsing MAY be extended in Task 5 only** (to carry per-message `usage`), and nowhere else. This supersedes the previous spec's freeze on it.
- **No changes to transport, PTY, Terminal view, or `PaneApprovalBarView`.** `PaneWorkspaceView.swift` may be touched only where a task explicitly says so.
- **Colours and fonts from `ShellPalette`/`ShellFont` only.** No raw `NSColor(red:...)` literals in view code.
- **Parsing runs off a fixed allowlist of block names.** Never a generic tag matcher — the corpus contains `<div>`, `<path>`, `<string>`, `<private>` as *user content*.
- **Every layout test is built with real content in it.** An empty container proves nothing about a constraint that only fails under content; the last pass shipped a column-width test that measured an empty stack and passed while the app was visibly broken.
- **Shared working tree.** Other Claude sessions edit this repo concurrently. Stage only the exact files each task names — never `git add -A`, never `git stash`.
- **Commit trailer:** `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`

**Test commands.** Full suite, required before every commit:

```bash
caffeinate -disu ./macos/build.sh test
```

Single test while iterating:

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests/testNameHere 2>&1 | tail -20
```

`caffeinate -disu` is mandatory — the suite hangs if the display sleeps. Run every suite in the FOREGROUND; do not background it or wrap it in a monitor.

---

### Task 1: The App view sits on the workspace ground, not terminal black

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (the `layer?.backgroundColor` assignment in `init`)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `PaneGroundView.colors` (already `static let`, `[NSColor]`, in `PaneWorkspaceView.swift`).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing test**

```swift
// MARK: - Ground

/// App mode is not a terminal, so it does not wear terminal black. It takes
/// the workspace ground's own gradient — the one `PaneGroundView` paints
/// behind the grid — because the reason panes go opaque ("a terminal theme
/// with any transparency washes its own text out") is about the terminal,
/// and there is no terminal theme here to protect.
func testTheAppViewPaintsTheWorkspaceGroundGradient() throws {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.layoutSubtreeIfNeeded()

    let gradient = try XCTUnwrap(view.layer as? CAGradientLayer, "not a flat fill")
    let colors = try XCTUnwrap(gradient.colors as? [CGColor])
    XCTAssertEqual(colors.count, 2)
    XCTAssertEqual(colors[0], PaneGroundView.colors[0].cgColor)
    XCTAssertEqual(colors[1], PaneGroundView.colors[1].cgColor)
}
```

- [ ] **Step 2: Run it and watch it fail**

Run the single-test command above with `testTheAppViewPaintsTheWorkspaceGroundGradient`.
Expected: FAIL — the view's layer is a plain `CALayer` with `paneBackgroundColor`.

- [ ] **Step 3: Make it pass**

In `PaneAppView.init`, replace the `wantsLayer = true` / `layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor` pair with a gradient layer, keeping the surrounding comment's intent but correcting it:

```swift
        // Not `PaneContainerView.paneBackgroundColor`. That opaque black
        // exists because a terminal theme with any transparency washes its own
        // text out (`PaneGroundView`'s own comment says so) — a constraint
        // about the *terminal*. App mode has no terminal theme to protect, so
        // it takes the workspace ground's gradient and reads as its own
        // surface rather than as a terminal wearing a chat's clothes.
        let ground = CAGradientLayer()
        ground.colors = PaneGroundView.colors.map(\.cgColor)
        ground.startPoint = CGPoint(x: 0.5, y: 0)
        ground.endPoint = CGPoint(x: 0.5, y: 1)
        wantsLayer = true
        layer = ground
```

Note: assigning `layer` before `wantsLayer = true` is the order AppKit requires for a custom layer class. If the glow's `insertSublayer` or the composer's stroke misbehaves after this, say so with evidence rather than reverting — they attach to `composerGlass`, not to this layer.

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): the App view sits on the workspace ground, not terminal black

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Speakers — avatars, a user bubble, agent prose on the ground

The biggest visual change. Rows stop being anonymous stacks and become turns with a speaker.

**Files:**
- Create: `macos/OmniAgent/PaneAppMessageRow.swift` — `PaneAppMessageRowView`, `PaneAppWorkGroupView` and the new avatar/bubble views, moved out of `PaneAppView.swift` because this task rewrites them and the host file is already 1605 lines.
- Modify: `macos/OmniAgent/PaneAppView.swift` (delete the moved types; `appendMessages` gains the run index)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (add the new file)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `TranscriptTurn` (`id`, `isUser`, `blocks`), `MarkdownBlock`, `PaneAppView.proseLabel/headingLabel/listView/codeBlockView/renderTable/toolLabel/workSummary`.
- Produces:
  - `PaneAppMessageRowView.init(turn: TranscriptTurn, showsAvatar: Bool)` — replaces `init(turn:)`. Tasks 4 and 8 construct rows with it.
  - `PaneAppAvatarView.init(kind: PaneAppAvatarView.Kind)` with `enum Kind { case agent, user }`.
  - `static func PaneAppMessageRowView.avatarFlags(for turns: [TranscriptTurn]) -> [Bool]` — pure; true where a turn opens a run of its speaker.

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Speakers

/// One avatar per run of consecutive same-role turns: it shows on the first
/// turn of a run and is omitted on the rest, reappearing only after the other
/// party speaks.
func testAvatarShowsOncePerRunOfTurns() {
    let turns = [
        TranscriptTurn(id: "1", isUser: true, blocks: [.text("hi")]),
        TranscriptTurn(id: "2", isUser: false, blocks: [.text("a")]),
        TranscriptTurn(id: "3", isUser: false, blocks: [.text("b")]),
        TranscriptTurn(id: "4", isUser: true, blocks: [.text("more")]),
        TranscriptTurn(id: "5", isUser: false, blocks: [.text("c")]),
    ]
    XCTAssertEqual(
        PaneAppMessageRowView.avatarFlags(for: turns),
        [true, true, false, true, true]
    )
}

func testAvatarFlagsOnAnEmptyConversation() {
    XCTAssertEqual(PaneAppMessageRowView.avatarFlags(for: []), [])
}

/// The user speaks in a bubble; the agent does not. A wide table inside an
/// agent bubble would push it to nearly the full column, so the bubble would
/// stop distinguishing anything exactly where answers are longest.
func testOnlyTheUserGetsABubble() {
    let user = PaneAppMessageRowView(
        turn: TranscriptTurn(id: "1", isUser: true, blocks: [.text("hi")]),
        showsAvatar: true
    )
    let agent = PaneAppMessageRowView(
        turn: TranscriptTurn(id: "2", isUser: false, blocks: [.text("hello")]),
        showsAvatar: true
    )

    XCTAssertNotNil(user.bubbleView, "the user's turn is in a bubble")
    XCTAssertNil(agent.bubbleView, "the agent's turn sits on the ground")
}

/// The avatar is built only when the row opens a run — a suppressed avatar is
/// absent, not hidden, so it takes no layout space in the gutter.
func testASuppressedAvatarIsNotBuilt() {
    let opening = PaneAppMessageRowView(
        turn: TranscriptTurn(id: "1", isUser: false, blocks: [.text("a")]),
        showsAvatar: true
    )
    let continuing = PaneAppMessageRowView(
        turn: TranscriptTurn(id: "2", isUser: false, blocks: [.text("b")]),
        showsAvatar: false
    )

    XCTAssertEqual(opening.descendants(PaneAppAvatarView.self).count, 1)
    XCTAssertEqual(continuing.descendants(PaneAppAvatarView.self).count, 0)
}

/// Agent prose is indented to clear the avatar gutter, so a continuing turn
/// still lines up under the one that opened the run.
func testAgentProseAlignsWhetherOrNotItsRowShowsAnAvatar() {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
    let window = show(view)
    defer { window.close() }
    view.appendMessages([
        TranscriptMessage(id: "1", isUser: false, blocks: [.text("first")]),
        TranscriptMessage(id: "2", isUser: true, blocks: [.text("you")]),
        TranscriptMessage(id: "3", isUser: false, blocks: [.text("second")]),
        TranscriptMessage(id: "4", isUser: false, blocks: [.text("third")]),
    ])
    view.layoutSubtreeIfNeeded()

    let rows = view.descendants(PaneAppMessageRowView.self)
    let second = try? XCTUnwrap(rows[2].proseOriginInWindow)
    let third = try? XCTUnwrap(rows[3].proseOriginInWindow)
    XCTAssertEqual(second?.x ?? -1, third?.x ?? -2, accuracy: 0.5)
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: compile failure — `avatarFlags`, `PaneAppAvatarView`, `bubbleView`, `proseOriginInWindow` and the two-argument initializer do not exist.

- [ ] **Step 3: Create `PaneAppMessageRow.swift`**

Move `PaneAppMessageRowView` and `PaneAppWorkGroupView` verbatim out of `PaneAppView.swift` into the new file first, and get the suite green on that move alone before changing behaviour — a move and a rewrite in one step is unreviewable.

Then add the avatar view and the run logic:

```swift
import AppKit

/// The speaker's mark beside a run of turns. Built only for the turn that
/// opens a run: a suppressed avatar is absent rather than hidden, so it takes
/// no space in the gutter and a continuing turn's prose still lines up.
final class PaneAppAvatarView: NSView {
    enum Kind { case agent, user }

    static let side: CGFloat = 28

    init(kind: Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .agent:
            layer?.backgroundColor = ShellPalette.accentIconTile.cgColor
            image.image = OmniAgentMark.image
            image.contentTintColor = .white
        case .user:
            layer?.backgroundColor = ShellPalette.iconTile.cgColor
            // ponytail: SF Symbol, not a bundled silhouette. The reference
            // image is a generic head-and-shoulders; the symbol is its
            // equivalent, tints with the palette, and stays sharp at any
            // scale. Swap in an imageset here if a specific face is wanted.
            image.image = NSImage(
                systemSymbolName: "person.crop.circle.fill",
                accessibilityDescription: "Dev Mode"
            )
            image.contentTintColor = ShellPalette.inkTertiary
        }

        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: Self.side - 8),
            image.heightAnchor.constraint(equalToConstant: Self.side - 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
```

On `PaneAppMessageRowView`, add:

```swift
    /// The vertical stack holding this turn's rendered blocks. Internal so
    /// Task 4's ordering tests can assert what landed in it, and so
    /// `proseOriginInWindow` can find the first prose view.
    private(set) var bodyStack: NSStackView?

    /// The user's bubble, or nil for an agent turn — the agent's prose sits
    /// directly on the ground. Internal so the layout tests can tell the two
    /// shapes apart without reading colours.
    private(set) var bubbleView: NSView?

    /// Where this row's first prose view starts, in window coordinates — the
    /// seam the alignment test measures.
    var proseOriginInWindow: CGPoint? {
        guard let body = bodyStack, let first = body.arrangedSubviews.first else { return nil }
        return first.convert(CGPoint.zero, to: nil)
    }

    /// True at each index whose turn opens a run of its speaker. Pure: the
    /// avatar rule is "once per run", and a run is exactly what
    /// `TranscriptTurn` already models.
    static func avatarFlags(for turns: [TranscriptTurn]) -> [Bool] {
        var flags: [Bool] = []
        var previousWasUser: Bool?
        for turn in turns {
            flags.append(previousWasUser != turn.isUser)
            previousWasUser = turn.isUser
        }
        return flags
    }
```

Rewrite `init` to take `showsAvatar`, lay out an avatar gutter of `PaneAppAvatarView.side + 10` on the leading edge, and wrap a user turn's body in a bubble:

```swift
    init(turn: TranscriptTurn, showsAvatar: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyStack = body

        // …existing block/run loop, unchanged, filling `body`…

        let gutter = PaneAppAvatarView.side + 10
        if turn.isUser {
            let bubble = NSView()
            bubble.wantsLayer = true
            bubble.layer?.backgroundColor = ShellPalette.cardFill.cgColor
            bubble.layer?.cornerRadius = 14
            bubble.layer?.cornerCurve = .continuous
            bubble.layer?.borderWidth = 1
            bubble.layer?.borderColor = ShellPalette.cardStroke.cgColor
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(body)
            bubbleView = bubble
            addSubview(bubble)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
                body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
                body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
                body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
                bubble.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                // The user's bubble hugs its content and never crosses the
                // column's midpoint, so a short question reads as a short
                // question rather than a full-width banner.
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: gutter),
            ])
        } else {
            addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
                body.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        if showsAvatar {
            let avatar = PaneAppAvatarView(kind: turn.isUser ? .user : .agent)
            addSubview(avatar)
            NSLayoutConstraint.activate([
                avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                turn.isUser
                    ? avatar.trailingAnchor.constraint(equalTo: trailingAnchor)
                    : avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            ])
        }
    }
```

The user's avatar sits on the trailing edge with the name label beside it; keep the name as `ShellFont.label("Dev Mode", font: ShellFont.ui(11, .semibold), color: ShellPalette.inkTertiary)`.

- [ ] **Step 4: Feed the flags from `appendMessages`**

In `PaneAppView.appendMessages`, the rebuild loop must pass the run flag. Because the flag of a turn depends on the one before it, compute flags for the whole `turns` array and index into it:

```swift
        let flags = PaneAppMessageRowView.avatarFlags(for: turns)
        for (offset, turn) in turns[firstChanged...].enumerated() {
            let row = PaneAppMessageRowView(turn: turn, showsAvatar: flags[firstChanged + offset])
            // …existing expansion-restore and width constraint…
        }
```

- [ ] **Step 5: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/PaneAppMessageRow.swift macos/OmniAgent/PaneAppView.swift \
        macos/OmniAgent.xcodeproj/project.pbxproj macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): the App view shows who is speaking

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: The system-block parser — allowlist only

The most dangerous task in the plan. Get the allowlist wrong and it deletes the user's own code from their transcript.

**Files:**
- Create: `macos/OmniAgent/PaneAppSystemBlocks.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`
- Test: `macos/OmniAgentTests/PaneAppSystemBlocksTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SystemBlockKind: String, CaseIterable { case taskNotification = "task-notification", systemReminder = "system-reminder", commandName = "command-name", commandMessage = "command-message", commandArgs = "command-args", localCommandStdout = "local-command-stdout", totalTokens = "total_tokens" }`
  - `struct SystemBlock: Equatable { let kind: SystemBlockKind; let body: String }`
  - `enum SystemBlockSplitter { static func split(_ text: String) -> [SystemBlockSegment] }`
  - `enum SystemBlockSegment: Equatable { case prose(String); case system(SystemBlock) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OmniAgent

/// The allowlist parser. Its whole reason for existing is in
/// `testUnknownTagsInAFenceSurviveUntouched`.
final class PaneAppSystemBlocksTests: XCTestCase {
    func testSplitsARecognisedBlockOutOfProse() {
        let segments = SystemBlockSplitter.split(
            "before\n<system-reminder>\nbe careful\n</system-reminder>\nafter"
        )
        XCTAssertEqual(segments, [
            .prose("before"),
            .system(SystemBlock(kind: .systemReminder, body: "be careful")),
            .prose("after"),
        ])
    }

    func testSplitsATaskNotificationWithNestedChildren() {
        let segments = SystemBlockSplitter.split(
            "<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n</task-notification>"
        )
        XCTAssertEqual(segments.count, 1)
        guard case .system(let block) = segments[0] else { return XCTFail("not a system block") }
        XCTAssertEqual(block.kind, .taskNotification)
        XCTAssertTrue(block.body.contains("<task-id>abc</task-id>"))
    }

    /// THE TRAP. Bruno's 528 transcripts contain `<div>` (204), `<path>` (138),
    /// `<string>` (501) and `<private>` (364) — every one of them his own code,
    /// in SVG, HTML and plist under discussion. A generic tag matcher would
    /// silently delete it. Nothing outside the allowlist is ever a block.
    func testUnknownTagsInAFenceSurviveUntouched() {
        let source = """
        here is some svg

        ```xml
        <div class="x">
          <path d="M0 0 L10 10"/>
          <string>value</string>
        </div>
        ```
        """
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    func testAnUnclosedBlockDegradesToProse() {
        let source = "text\n<system-reminder>\nnever closed"
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    func testTotalTokensIsRecognised() {
        let segments = SystemBlockSplitter.split("<total_tokens>15000000 tokens left</total_tokens>")
        XCTAssertEqual(segments, [
            .system(SystemBlock(kind: .totalTokens, body: "15000000 tokens left")),
        ])
    }

    func testTextWithNoBlocksIsOneProseSegment() {
        XCTAssertEqual(SystemBlockSplitter.split("just words"), [.prose("just words")])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppSystemBlocksTests 2>&1 | tail -20
```

Expected: compile failure — none of the types exist.

- [ ] **Step 3: Implement the splitter**

```swift
import Foundation

/// The system blocks the App view folds away. A fixed list, deliberately:
/// the transcript corpus also contains `<div>`, `<path>`, `<string>` and
/// `<private>` as *content* — SVG, HTML and plist in code under discussion —
/// so a generic tag matcher would silently delete the user's own work. A tag
/// not named here is prose and stays prose, verbatim.
enum SystemBlockKind: String, CaseIterable {
    case taskNotification = "task-notification"
    case systemReminder = "system-reminder"
    case commandName = "command-name"
    case commandMessage = "command-message"
    case commandArgs = "command-args"
    case localCommandStdout = "local-command-stdout"
    case totalTokens = "total_tokens"
}

struct SystemBlock: Equatable {
    let kind: SystemBlockKind
    let body: String
}

enum SystemBlockSegment: Equatable {
    case prose(String)
    case system(SystemBlock)
}

enum SystemBlockSplitter {
    /// Splits raw assistant text into prose and recognised system blocks.
    ///
    /// Scans for an opening tag from the allowlist and its matching close.
    /// An unclosed block is not a block — the text stays prose, because a
    /// reply still being written ends mid-anything and losing content is
    /// worse than losing formatting.
    static func split(_ text: String) -> [SystemBlockSegment] {
        var segments: [SystemBlockSegment] = []
        var prose = ""
        var rest = Substring(text)

        while let open = nextOpening(in: rest) {
            let close = "</\(open.kind.rawValue)>"
            guard let closeRange = rest[open.range.upperBound...].range(of: close) else {
                break
            }
            prose += rest[rest.startIndex..<open.range.lowerBound]
            flush(&prose, into: &segments)
            let body = rest[open.range.upperBound..<closeRange.lowerBound]
            segments.append(.system(SystemBlock(
                kind: open.kind,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )))
            rest = rest[closeRange.upperBound...]
        }

        prose += rest
        flush(&prose, into: &segments)
        return segments.isEmpty ? [.prose(text)] : segments
    }

    private static func flush(_ prose: inout String, into segments: inout [SystemBlockSegment]) {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        prose = ""
        guard !trimmed.isEmpty else { return }
        segments.append(.prose(trimmed))
    }

    private static func nextOpening(
        in text: Substring
    ) -> (kind: SystemBlockKind, range: Range<Substring.Index>)? {
        var best: (kind: SystemBlockKind, range: Range<Substring.Index>)?
        for kind in SystemBlockKind.allCases {
            guard let found = text.range(of: "<\(kind.rawValue)>") else { continue }
            if best == nil || found.lowerBound < best!.range.lowerBound {
                best = (kind, found)
            }
        }
        return best
    }
}
```

Note the unclosed case: `break` leaves the remaining text to be appended as prose, so `testAnUnclosedBlockDegradesToProse` gets the whole original string back. Verify that is what actually happens rather than assuming — if the trim changes the string, adjust the test's expectation to the trimmed form and say so.

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppSystemBlocks.swift macos/OmniAgentTests/PaneAppSystemBlocksTests.swift \
        macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "feat(macos): parse system blocks off a fixed allowlist

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: System blocks render as collapsed chips, in place

**Files:**
- Modify: `macos/OmniAgent/PaneAppMessageRow.swift` (a chip view; route `.text` blocks through the splitter)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `SystemBlockSplitter.split`, `SystemBlock`, `SystemBlockKind` (Task 3); `PaneAppMessageRowView.init(turn:showsAvatar:)` (Task 2).
- Produces: `final class PaneAppSystemChipView: NSView` with `private(set) var isExpanded: Bool` and `func toggle()`.

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - System chips

func testASystemBlockRendersAsACollapsedChipInPlace() {
    let row = PaneAppMessageRowView(
        turn: TranscriptTurn(id: "1", isUser: false, blocks: [
            .text("before\n<system-reminder>\nbe careful\n</system-reminder>\nafter"),
        ]),
        showsAvatar: true
    )

    let chips = row.descendants(PaneAppSystemChipView.self)
    XCTAssertEqual(chips.count, 1)
    XCTAssertFalse(chips[0].isExpanded, "collapsed by default")

    let body = try? XCTUnwrap(row.bodyStack)
    let kinds = body?.arrangedSubviews.map { $0 is PaneAppSystemChipView } ?? []
    XCTAssertEqual(kinds, [false, true, false], "prose, chip, prose — in place")
}

func testExpandingASystemChipRevealsItsBody() {
    let chip = PaneAppSystemChipView(block: SystemBlock(kind: .systemReminder, body: "be careful"))
    let detail = chip.descendants(NSTextField.self).filter { $0.stringValue.contains("be careful") }
    XCTAssertEqual(detail.count, 1, "body is built up front, not on expand")

    let before = chip.fittingSize.height
    chip.toggle()
    XCTAssertTrue(chip.isExpanded)
    XCTAssertGreaterThan(chip.fittingSize.height, before)
}

/// `<total_tokens>` is one live number, not an event. It belongs in the stats
/// bar and never in the conversation flow.
func testTotalTokensProducesNoChip() {
    let row = PaneAppMessageRowView(
        turn: TranscriptTurn(id: "1", isUser: false, blocks: [
            .text("answer\n<total_tokens>15000000 tokens left</total_tokens>"),
        ]),
        showsAvatar: true
    )
    XCTAssertEqual(row.descendants(PaneAppSystemChipView.self).count, 0)
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: compile failure — `PaneAppSystemChipView` does not exist.

- [ ] **Step 3: Implement the chip and route text through the splitter**

```swift
/// One folded-away system block, at the point in the conversation where it
/// happened — position is information a side panel would throw away.
final class PaneAppSystemChipView: NSView {
    private(set) var isExpanded = false
    private let chevron: NSTextField
    private let detail = NSStackView()

    init(block: SystemBlock) {
        chevron = ShellFont.label("⌄", font: ShellFont.ui(11), color: ShellPalette.inkFaint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = ShellFont.label(
            Self.label(for: block.kind),
            font: ShellFont.ui(12),
            color: ShellPalette.inkMuted
        )
        let header = NSStackView(views: [chevron, title])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        // Monospace is allowed *inside* an expanded chip and nowhere else in
        // the flow — the body is machinery, and machinery reads as machinery.
        let body = NSTextField(labelWithString: block.body)
        body.isSelectable = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.font = ShellFont.mono(11)
        body.textColor = ShellPalette.inkTertiary
        body.translatesAutoresizingMaskIntoConstraints = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.isHidden = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.addArrangedSubview(body)

        let stack = NSStackView(views: [header, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        header.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func handleClick() { toggle() }

    func toggle() {
        isExpanded.toggle()
        detail.isHidden = !isExpanded
        chevron.stringValue = isExpanded ? "⌃" : "⌄"
    }

    private static func label(for kind: SystemBlockKind) -> String {
        switch kind {
        case .taskNotification: return "agent finished"
        case .systemReminder: return "system note"
        case .commandName, .commandMessage, .commandArgs: return "command"
        case .localCommandStdout: return "command output"
        case .totalTokens: return "tokens"
        }
    }
}
```

In `blockViews(for:)`'s `.text` case, run the raw text through `SystemBlockSplitter.split` *before* `MarkdownBlock.parse`, mapping `.prose` through the existing markdown path and `.system` to a chip — except `.totalTokens`, which is dropped here and read by Task 6's stats bar instead:

```swift
        case .text(let text):
            return SystemBlockSplitter.split(text).flatMap { segment -> [NSView] in
                switch segment {
                case .prose(let prose):
                    return MarkdownBlock.parse(prose).map { markdown -> NSView in
                        // …existing markdown switch, unchanged…
                    }
                case .system(let block):
                    guard block.kind != .totalTokens else { return [] }
                    return [PaneAppSystemChipView(block: block)]
                }
            }
```

- [ ] **Step 4: Verify the one-font rule holds (spec §6)**

Monospace is permitted in exactly three places: fenced code blocks, rendered
tables, and the inside of an *expanded* system chip. Everything else — prose,
headings, list items, tool lines, chip headers, the stats bar — is
`ShellFont.ui`.

Check it, and fix any violation you find:

```bash
grep -n "ShellFont.mono" macos/OmniAgent/PaneAppView.swift macos/OmniAgent/PaneAppMessageRow.swift
```

Expected: `codeBlockView`, the table path, and `PaneAppSystemChipView`'s body.
Anything else is a bug — report it with the line rather than silently changing
an unrelated view.

Add a test pinning the rule for the one that regressed before:

```swift
/// A collapsed chip's header is UI font like everything else — only its
/// expanded body is machinery, and only machinery gets monospace.
func testACollapsedChipHeaderIsNotMonospaced() throws {
    let chip = PaneAppSystemChipView(block: SystemBlock(kind: .systemReminder, body: "x"))
    let header = try XCTUnwrap(
        chip.descendants(NSTextField.self).first { $0.stringValue == "system note" }
    )
    XCTAssertEqual(header.font?.fontName, ShellFont.ui(12).fontName)
}
```

- [ ] **Step 5: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/PaneAppMessageRow.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): system blocks fold into collapsed chips where they happened

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Per-conversation token and context sums

**Files:**
- Modify: `macos/OmniAgent/ClaudeTranscript.swift` — `TranscriptMessage` gains `usage`; `decode` reads it. **This is the one sanctioned change to the reader's parsing.**
- Test: `macos/OmniAgentTests/ClaudeTranscriptTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct TranscriptUsage: Equatable { let input: Int; let output: Int; let cacheRead: Int; let cacheCreation: Int }` with `var contextTokens: Int { input + cacheRead + cacheCreation }` and `var totalTokens: Int { input + output + cacheRead + cacheCreation }`
  - `TranscriptMessage.usage: TranscriptUsage?`
  - `enum ConversationCost { static func totals(_ turns: [TranscriptTurn]) -> Int; static func context(_ turns: [TranscriptTurn]) -> Int }` — **no**, see below: totals must come from messages, so this lives on the view. Produce instead:
  - `static func TranscriptUsage.total(of usages: [TranscriptUsage]) -> Int`
  - `static func TranscriptUsage.latestContext(of usages: [TranscriptUsage]) -> Int`

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Usage

func testDecodeReadsPerMessageUsage() throws {
    let line = """
    {"type":"assistant","uuid":"1","message":{"content":"hi","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}
    """
    let url = tempDirectory.appendingPathComponent("t.jsonl")
    try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

    let messages = ClaudeTranscriptReader(url: url).poll().messages
    let usage = try XCTUnwrap(messages.first?.usage)
    XCTAssertEqual(usage.input, 10)
    XCTAssertEqual(usage.output, 5)
    XCTAssertEqual(usage.cacheRead, 100)
    XCTAssertEqual(usage.cacheCreation, 20)
    XCTAssertEqual(usage.contextTokens, 130, "context is input + cache read + cache creation")
    XCTAssertEqual(usage.totalTokens, 135)
}

func testARowWithNoUsageContributesNothing() {
    let a = TranscriptUsage(input: 10, output: 5, cacheRead: 0, cacheCreation: 0)
    let b = TranscriptUsage(input: 1, output: 1, cacheRead: 0, cacheCreation: 0)
    XCTAssertEqual(TranscriptUsage.total(of: [a, b]), 17)
    XCTAssertEqual(TranscriptUsage.total(of: []), 0)
}

/// Context is the CURRENT window fill, so it is the latest row's figure, not
/// a sum — summing it would grow without bound and mean nothing.
func testContextIsTheLatestRowNotASum() {
    let older = TranscriptUsage(input: 10, output: 0, cacheRead: 100, cacheCreation: 0)
    let newer = TranscriptUsage(input: 20, output: 0, cacheRead: 300, cacheCreation: 5)
    XCTAssertEqual(TranscriptUsage.latestContext(of: [older, newer]), 325)
    XCTAssertEqual(TranscriptUsage.latestContext(of: []), 0)
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: compile failure — `TranscriptUsage` does not exist and `TranscriptMessage` has no `usage`.

- [ ] **Step 3: Implement**

Append to `ClaudeTranscript.swift`:

```swift
/// One assistant row's token usage, as Claude Code writes it.
///
/// Read per message rather than aggregated per project: the App view's
/// readouts are about *this conversation*, and `UsageAnalytics` buckets by
/// project, which is the wrong unit for a pane.
struct TranscriptUsage: Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int

    /// What the model is currently carrying — everything that had to be sent,
    /// which is the window fill. Output is excluded: it is generated, not
    /// carried.
    var contextTokens: Int { input + cacheRead + cacheCreation }

    /// Everything this row cost, in and out.
    var totalTokens: Int { input + output + cacheRead + cacheCreation }

    static func total(of usages: [TranscriptUsage]) -> Int {
        usages.reduce(0) { $0 + $1.totalTokens }
    }

    /// The CURRENT window fill — the latest row's figure. Summing context
    /// across rows would grow without bound and mean nothing.
    static func latestContext(of usages: [TranscriptUsage]) -> Int {
        usages.last?.contextTokens ?? 0
    }
}
```

Add `let usage: TranscriptUsage?` to `TranscriptMessage` (with a default of `nil` in its memberwise use sites so existing tests still compile), and in `decode`, after the blocks guard:

```swift
        let usage = (message["usage"] as? [String: Any]).map {
            TranscriptUsage(
                input: $0["input_tokens"] as? Int ?? 0,
                output: $0["output_tokens"] as? Int ?? 0,
                cacheRead: $0["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: $0["cache_creation_input_tokens"] as? Int ?? 0
            )
        }
        return TranscriptMessage(id: uuid, isUser: type == "user", blocks: blocks, usage: usage)
```

`TranscriptTurn.append` must carry usages forward: give `TranscriptTurn` a `var usages: [TranscriptUsage]` appended alongside blocks, so the view can sum a conversation without re-reading the file.

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/ClaudeTranscript.swift macos/OmniAgentTests/ClaudeTranscriptTests.swift
git commit -m "feat(macos): carry per-message token usage through the transcript reader

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: The `/usage` limits fetcher

**Files:**
- Create: `macos/OmniAgent/ClaudeUsageLimits.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`
- Test: `macos/OmniAgentTests/ClaudeUsageLimitsTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct ClaudeUsageLimits: Equatable { let sessionPercent: Int?; let sessionResets: String?; let weekPercent: Int?; let weekResets: String?; let modelName: String?; let modelPercent: Int? }`
  - `static func ClaudeUsageLimits.parse(_ output: String) -> ClaudeUsageLimits`
  - `final class ClaudeUsageLimitsPoller` with `static let shared`, `private(set) var latest: ClaudeUsageLimits?`, `var onChange: (() -> Void)?`, `func refresh()`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OmniAgent

final class ClaudeUsageLimitsTests: XCTestCase {
    /// The real shape, captured from `claude -p "/usage"` on 2026-08-25.
    private let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 9% used · resets Aug 25 at 2:10pm (Europe/Berlin)
    Current week (all models): 37% used · resets Aug 28 at 11am (Europe/Berlin)
    Current week (Fable): 10% used · resets Aug 28 at 11am (Europe/Berlin)
    """

    func testParsesSessionAndWeek() {
        let limits = ClaudeUsageLimits.parse(sample)
        XCTAssertEqual(limits.sessionPercent, 9)
        XCTAssertEqual(limits.sessionResets, "Aug 25 at 2:10pm")
        XCTAssertEqual(limits.weekPercent, 37)
        XCTAssertEqual(limits.weekResets, "Aug 28 at 11am")
    }

    func testParsesThePerModelWeeklyLine() {
        let limits = ClaudeUsageLimits.parse(sample)
        XCTAssertEqual(limits.modelName, "Fable")
        XCTAssertEqual(limits.modelPercent, 10)
    }

    /// A failed or changed `/usage` must never blank the bar or throw — every
    /// field is optional and garbage yields all-nil.
    func testGarbageYieldsAllNilRatherThanThrowing() {
        let limits = ClaudeUsageLimits.parse("command not found\n")
        XCTAssertNil(limits.sessionPercent)
        XCTAssertNil(limits.weekPercent)
        XCTAssertNil(limits.modelPercent)
    }

    func testEmptyInput() {
        XCTAssertEqual(ClaudeUsageLimits.parse(""), ClaudeUsageLimits.parse("   \n  "))
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: compile failure — the type does not exist.

- [ ] **Step 3: Implement parse + poller**

```swift
import Foundation

/// Claude's rate-limit windows, as `/usage` reports them.
///
/// Every field optional: a failed fetch, a timeout, or a changed output format
/// must leave the readout stale rather than blank, and must never throw.
struct ClaudeUsageLimits: Equatable {
    let sessionPercent: Int?
    let sessionResets: String?
    let weekPercent: Int?
    let weekResets: String?
    let modelName: String?
    let modelPercent: Int?

    static let empty = ClaudeUsageLimits(
        sessionPercent: nil, sessionResets: nil,
        weekPercent: nil, weekResets: nil,
        modelName: nil, modelPercent: nil
    )

    /// Line-oriented, because the output is line-oriented. Anything that does
    /// not match is ignored rather than treated as an error.
    static func parse(_ output: String) -> ClaudeUsageLimits {
        var session: (Int, String?)?
        var week: (Int, String?)?
        var model: (String, Int)?

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let percent = percent(in: line) else { continue }
            let resets = resetPhrase(in: line)
            if line.hasPrefix("Current session:") {
                session = (percent, resets)
            } else if line.hasPrefix("Current week (all models)") {
                week = (percent, resets)
            } else if line.hasPrefix("Current week ("),
                      let open = line.firstIndex(of: "("),
                      let close = line.firstIndex(of: ")") {
                model = (String(line[line.index(after: open)..<close]), percent)
            }
        }

        return ClaudeUsageLimits(
            sessionPercent: session?.0, sessionResets: session?.1,
            weekPercent: week?.0, weekResets: week?.1,
            modelName: model?.0, modelPercent: model?.1
        )
    }

    /// The integer immediately before "% used".
    private static func percent(in line: String) -> Int? {
        guard let range = line.range(of: "% used") else { return nil }
        let digits = line[line.startIndex..<range.lowerBound].reversed()
            .prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }

    /// What follows "resets ", minus any trailing parenthesised timezone.
    private static func resetPhrase(in line: String) -> String? {
        guard let range = line.range(of: "resets ") else { return nil }
        var phrase = String(line[range.upperBound...])
        if let paren = phrase.range(of: " (") {
            phrase = String(phrase[phrase.startIndex..<paren.lowerBound])
        }
        return phrase.trimmingCharacters(in: .whitespaces)
    }
}
```

And the poller, in the same file:

```swift
/// One app-wide poller for `/usage`.
///
/// Deliberately a singleton with a long interval: `/usage` is a real request
/// against the very limits it reports, so measuring usage consumes usage.
/// The limits are account-global and identical in every pane, so eight panes
/// polling would be eight times the cost for one number.
final class ClaudeUsageLimitsPoller {
    static let shared = ClaudeUsageLimitsPoller()

    private(set) var latest: ClaudeUsageLimits?
    var onChange: (() -> Void)?

    /// Minutes, not seconds. See the type's own comment.
    static let interval: TimeInterval = 300

    private var inFlight = false
    private let queue = DispatchQueue(label: "com.omniagent.usage-limits")

    /// Overridden by tests so the suite never shells out to `claude`.
    var runnerForTesting: (() -> String)?

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let output = self.runnerForTesting?() ?? Self.runUsage()
            let parsed = ClaudeUsageLimits.parse(output)
            DispatchQueue.main.async {
                self.inFlight = false
                // A fetch that parsed nothing leaves the last good value in
                // place: stale beats blank.
                if parsed != .empty { self.latest = parsed }
                self.onChange?()
            }
        }
    }

    private static func runUsage() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "-p", "/usage"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Confirm no test shells out to `claude` — the suite must not consume the user's quota.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/ClaudeUsageLimits.swift macos/OmniAgentTests/ClaudeUsageLimitsTests.swift \
        macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "feat(macos): read Claude's session and week limits from /usage

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 7: The stats bar

**Files:**
- Create: `macos/OmniAgent/PaneAppStatsBar.swift`
- Modify: `macos/OmniAgent/PaneAppView.swift` (host it; feed conversation figures; drive the poller)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `TranscriptUsage.total(of:)` / `.latestContext(of:)` (Task 5); `ClaudeUsageLimits`, `ClaudeUsageLimitsPoller` (Task 6); `WorkspaceGlass.sheet(cornerRadius:content:)`.
- Produces: `final class PaneAppStatsBar: NSView` with `var tokens: Int`, `var context: Int`, `var limits: ClaudeUsageLimits?`, and `private(set) var visibleReadoutCount: Int`.

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Stats bar

func testTheStatsBarShowsFourReadoutsWhenItFits() {
    let bar = PaneAppStatsBar()
    bar.frame = NSRect(x: 0, y: 0, width: 880, height: 34)
    bar.tokens = 341_000
    bar.context = 130_500
    bar.limits = ClaudeUsageLimits.parse(
        "Current session: 9% used · resets Aug 25 at 2:10pm\n"
        + "Current week (all models): 37% used · resets Aug 28 at 11am"
    )
    bar.layoutSubtreeIfNeeded()

    XCTAssertEqual(bar.visibleReadoutCount, 4)
    let text = bar.descendants(NSTextField.self).map(\.stringValue).joined(separator: " ")
    XCTAssertTrue(text.contains("9%"))
    XCTAssertTrue(text.contains("37%"))
}

/// Panes live in a grid and are often narrow. The bar keeps Context — the only
/// readout that changes minute to minute — and puts the rest behind a tap,
/// rather than wrapping or clipping.
func testTheStatsBarCollapsesOnANarrowPane() {
    let bar = PaneAppStatsBar()
    bar.frame = NSRect(x: 0, y: 0, width: 320, height: 34)
    bar.tokens = 341_000
    bar.context = 130_500
    bar.layoutSubtreeIfNeeded()

    XCTAssertEqual(bar.visibleReadoutCount, 1)
    let text = bar.descendants(NSTextField.self).map(\.stringValue).joined(separator: " ")
    XCTAssertTrue(text.lowercased().contains("context"))
}

/// A pane that has never had a successful fetch says so rather than showing a
/// confident zero.
func testUnknownLimitsReadAsPendingNotZero() {
    let bar = PaneAppStatsBar()
    bar.frame = NSRect(x: 0, y: 0, width: 880, height: 34)
    bar.limits = nil
    bar.layoutSubtreeIfNeeded()

    let text = bar.descendants(NSTextField.self).map(\.stringValue).joined(separator: " ")
    XCTAssertFalse(text.contains("0%"), "never a fabricated zero")
    XCTAssertTrue(text.contains("—"))
}

func testTheBarSitsOnGlassBelowTheHeaderAndAboveTheTranscript() throws {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
    let window = show(view)
    defer { window.close() }
    view.layoutSubtreeIfNeeded()

    let bar = try XCTUnwrap(view.descendants(PaneAppStatsBar.self).first)
    XCTAssertLessThan(bar.frame.minY, view.frame.height / 2, "pinned to the top")
    XCTAssertGreaterThan(view.scrollView.contentInsets.top, 0, "transcript clears it")
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: compile failure — `PaneAppStatsBar` does not exist.

- [ ] **Step 3: Implement the bar**

```swift
import AppKit

/// Four readouts over the transcript: what this conversation has cost, how
/// full its context is, and how much of Claude's session and week windows are
/// gone.
///
/// The first two are per *conversation* — summed from this pane's own
/// transcript, not from `UsageAnalytics`, which buckets per project and is the
/// wrong unit for a pane. The last two are account-global and identical in
/// every pane, which is why one app-wide poller feeds them all.
final class PaneAppStatsBar: NSView {
    /// Below this width four readouts crowd or wrap, so the bar keeps the one
    /// that changes minute to minute and puts the rest behind a tap.
    static let fourUpMinimumWidth: CGFloat = 560

    var tokens: Int = 0 { didSet { needsLayout = true } }
    var context: Int = 0 { didSet { needsLayout = true } }
    var limits: ClaudeUsageLimits? { didSet { needsLayout = true } }

    private(set) var visibleReadoutCount = 4

    private let tokensReadout = Readout(title: "Tokens")
    private let contextReadout = Readout(title: "Context")
    private let sessionReadout = Readout(title: "Session")
    private let weekReadout = Readout(title: "Week")
    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        // The same glass the composer and the approval card use, via the same
        // shared helper — three surfaces agreeing by construction rather than
        // by three hand-rolled availability branches.
        if let glass = WorkspaceGlass.sheet(cornerRadius: 12) {
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            layer?.backgroundColor = ShellPalette.fieldFill.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        for readout in [tokensReadout, contextReadout, sessionReadout, weekReadout] {
            row.addArrangedSubview(readout)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        tokensReadout.value = Self.compact(tokens)
        contextReadout.value = Self.compact(context)
        // Never a fabricated zero: a pane that has had no successful fetch
        // says so, because "0% used" is a claim and "—" is an admission.
        sessionReadout.value = Self.percent(limits?.sessionPercent)
        weekReadout.value = Self.percent(limits?.weekPercent)

        let wanted = bounds.width >= Self.fourUpMinimumWidth ? 4 : 1
        guard wanted != visibleReadoutCount else { return }
        visibleReadoutCount = wanted
        let collapsed = wanted == 1
        tokensReadout.isHidden = collapsed
        sessionReadout.isHidden = collapsed
        weekReadout.isHidden = collapsed
    }

    /// `341000` reads `341k`. A raw seven-digit number in a 34pt bar is noise.
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return "\(value / 1_000)k"
        default: return "\(value)"
        }
    }

    static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    /// One label pair: a muted title over its value.
    private final class Readout: NSView {
        private let valueLabel = ShellFont.label("—", font: ShellFont.ui(13, .semibold), color: ShellPalette.ink)

        var value: String {
            get { valueLabel.stringValue }
            set { valueLabel.stringValue = newValue }
        }

        init(title: String) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let titleLabel = ShellFont.label(
                title,
                font: ShellFont.ui(10),
                color: ShellPalette.inkFaint
            )
            let stack = NSStackView(views: [titleLabel, valueLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    }
}
```

Note the `layout()` shape: the readout values are set unconditionally, but the
show/hide work is guarded on an actual change so `layout()` cannot recurse —
the same discipline `PaneAppView.layout()` already uses for its composer
clearance.

- [ ] **Step 3b: Host it in `PaneAppView`**

```swift
    let statsBar = PaneAppStatsBar()
```

Pin it below the view's top edge, inside the same centred column as the
transcript (reuse `Self.transcriptColumnWidth` and the `.defaultHigh`-beating
priority already there — a `.defaultHigh` cap loses to content, which is
exactly how the transcript column shipped broken):

```swift
            statsBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statsBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            statsBar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
```

In `layout()`, derive the transcript's top inset from the bar's real laid-out
height — never a constant. The previous plan hardcoded a clearance that was
wrong by 3pt and had to be measured and fixed:

```swift
        let topClearance = statsBar.frame.height + 16
        if abs(scrollView.contentInsets.top - topClearance) > 0.5 {
            scrollView.contentInsets.top = topClearance
        }
```

Feed the conversation figures at the end of each poll cycle, from the usages
`TranscriptTurn` accumulated in Task 5:

```swift
        let usages = turns.flatMap(\.usages)
        statsBar.tokens = TranscriptUsage.total(of: usages)
        statsBar.context = TranscriptUsage.latestContext(of: usages)
```

And drive the shared poller when the view goes live, never per poll tick:

```swift
        // One app-wide poller, refreshed in minutes. `/usage` is a real
        // request against the very limits it reports, so measuring usage
        // consumes usage — eight panes polling would be eight times the cost
        // for one account-global number.
        ClaudeUsageLimitsPoller.shared.onChange = { [weak self] in
            self?.statsBar.limits = ClaudeUsageLimitsPoller.shared.latest
        }
        ClaudeUsageLimitsPoller.shared.refresh()
```

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppStatsBar.swift macos/OmniAgent/PaneAppView.swift \
        macos/OmniAgent.xcodeproj/project.pbxproj macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): a liquid-glass stats bar over the App view transcript

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 8: Arrival animation

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (`appendMessages`)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `reducedMotion` (already on `PaneAppView`).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Arrival

/// Rows genuinely arrive in batches on the 0.3s poll, so animating an arrival
/// reflects something true. This is not a typewriter: the text is complete the
/// instant it is on screen.
func testANewlyAppendedRowAnimatesIn() throws {
    let view = makeView()
    view.reducedMotionForTesting = false
    view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
    let window = show(view)
    defer { window.close() }

    view.appendMessages([TranscriptMessage(id: "1", isUser: false, blocks: [.text("hi")])])

    let row = try XCTUnwrap(view.descendants(PaneAppMessageRowView.self).first)
    XCTAssertNotNil(row.layer?.animation(forKey: "om-arrive"))
}

func testNoArrivalAnimationUnderReduceMotion() throws {
    let view = makeView()
    view.reducedMotionForTesting = true
    view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
    let window = show(view)
    defer { window.close() }

    view.appendMessages([TranscriptMessage(id: "1", isUser: false, blocks: [.text("hi")])])

    let row = try XCTUnwrap(view.descendants(PaneAppMessageRowView.self).first)
    XCTAssertNil(row.layer?.animation(forKey: "om-arrive"))
    XCTAssertEqual(row.layer?.opacity ?? 0, 1, accuracy: 0.01, "visible, just not animated")
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: FAIL — no animation is ever added.

- [ ] **Step 3: Implement**

In `appendMessages`, after `layoutSubtreeIfNeeded()`, animate only the rows added in this call:

```swift
    /// A row that just arrived fades and rises into place.
    ///
    /// Not a typewriter. The transcript JSONL only gains complete rows, so
    /// there are no tokens to stream — but rows genuinely do arrive in batches
    /// on the poll, and animating that arrival reflects a real event. A
    /// typewriter reveal on already-complete text would look like streaming
    /// while deliberately making a finished answer slower to read.
    private func animateArrival(of row: NSView) {
        guard !reducedMotion else { return }
        row.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 8
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = 0.2
        group.timingFunction = ShellMotion.timing
        row.layer?.add(group, forKey: "om-arrive")
    }
```

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): a newly arrived row fades and rises into the App view

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 9: The composer takes the pane's colour, and always takes focus

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` — extract `PaneHeaderView.claudeTint(for:) -> NSColor?` from `colorDotImage(for:)`; pass the descriptor's colour into `PaneAppView`; make the composer first responder after a pane move.
- Modify: `macos/OmniAgent/PaneAppView.swift` — `var paneTint: NSColor?`; the glow and stroke use it; whole-card click focuses the field at the end of the draft.
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `descriptor.claudeColor: String`.
- Produces: `PaneAppView.paneTint: NSColor?`; `PaneHeaderView.claudeTint(for: String) -> NSColor?`.

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Pane colour and focus

func testTheGlowTakesThePanesOwnColour() throws {
    let view = makeView()
    view.reducedMotionForTesting = false
    view.isKeyWindowForTesting = true
    view.isLive = true
    view.paneTint = ShellPalette.amber
    view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
    let window = show(view)
    defer { window.close() }

    window.makeFirstResponder(view.composerField)
    view.layoutSubtreeIfNeeded()

    let container = try XCTUnwrap(view.glowContainerForTesting)
    let gradient = try XCTUnwrap(container.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
    let colors = try XCTUnwrap(gradient.colors as? [CGColor])
    XCTAssertTrue(
        colors.contains { $0.components?.prefix(3) == ShellPalette.amber.cgColor.components?.prefix(3) },
        "an amber pane gets an amber glow"
    )
}

func testAPaneWithNoColourKeepsTheDefaultRamp() throws {
    let view = makeView()
    view.paneTint = nil
    // …same setup…
    let container = try XCTUnwrap(view.glowContainerForTesting)
    let gradient = try XCTUnwrap(container.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
    let colors = try XCTUnwrap(gradient.colors as? [CGColor])
    XCTAssertTrue(colors.contains { $0 == ShellPalette.accentPurple.cgColor })
}

/// The card is 107pt tall and the field is one line near its top, so most of
/// it looks typable and is not. A click anywhere in the card focuses the
/// field, caret at the END of the draft — never mid-word, never selecting it.
func testClickingTheComposerCardFocusesTheFieldAtTheEnd() throws {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
    let window = show(view)
    defer { window.close() }
    view.composerField.stringValue = "half typed"

    view.focusComposerAtEndOfDraft()

    XCTAssertTrue(view.composerField.currentEditorIsFirstResponder)
    let editor = try XCTUnwrap(view.composerField.currentEditor())
    XCTAssertEqual(editor.selectedRange, NSRange(location: 10, length: 0))
}

func testClaudeTintResolvesTheEightColourNames() {
    XCTAssertEqual(PaneHeaderView.claudeTint(for: "orange"), .systemOrange)
    XCTAssertEqual(PaneHeaderView.claudeTint(for: "blue"), .systemBlue)
    XCTAssertNil(PaneHeaderView.claudeTint(for: "default"), "no colour is not a colour")
    XCTAssertNil(PaneHeaderView.claudeTint(for: "chartreuse"))
}
```

- [ ] **Step 2: Run them and watch them fail**

Expected: compile failure — `paneTint`, `focusComposerAtEndOfDraft`, `claudeTint(for:)` and `glowContainerForTesting` do not exist.

- [ ] **Step 3: Extract the tint and wire it through**

In `PaneWorkspaceView.swift`, refactor `colorDotImage(for:)` so its switch lives in a new `static func claudeTint(for color: String) -> NSColor?` returning `nil` for `"default"` and anything unrecognised, and have `colorDotImage` call it (falling back to its existing `NSColor(white: 1, alpha: 0.4)` when nil). Do not duplicate the table.

In `makeAppViewIfNeeded`, set `view.paneTint = PaneHeaderView.claudeTint(for: descriptor.claudeColor)`, and update it wherever `header.claudeColor` is updated so a `/color` change reaches the composer live.

In `PaneAppView`, `paneTint` triggers `updateComposerGlow()` and `setComposerFocused(isComposerFocused)`; the glow's colour ramp uses `paneTint ?? ShellPalette.accent` → `paneTint ?? ShellPalette.accentPurple`.

- [ ] **Step 4: Whole-card click and focus-after-move**

Add a click recognizer on `composerGlass` (not on the buttons, which keep theirs) calling:

```swift
    /// Focus the field with the caret at the end of any existing draft.
    ///
    /// The glass card is ~107pt tall while the field is a single line near its
    /// top, so most of the card looks typable and is not. A click anywhere in
    /// it lands the caret where the user would keep typing — the end — rather
    /// than mid-word or over a selected draft.
    func focusComposerAtEndOfDraft() {
        window?.makeFirstResponder(composerField)
        if let editor = composerField.currentEditor() {
            editor.selectedRange = NSRange(location: composerField.stringValue.count, length: 0)
        }
    }
```

In `PaneWorkspaceView`, call `appView?.focusComposerAtEndOfDraft()` from the paths that leave the App view on screen and focused after a move — the same places `applyLayout` re-frames a pane and `focusPane` runs. The rule to satisfy: if the App view is the pane's active content and the pane is focused, the caret is in the composer.

Expose `var glowContainerForTesting: CALayer? { composerGlow }` and `var currentEditorIsFirstResponder: Bool` on `HomeComposerField` (or assert via `window.firstResponder === composerField.currentEditor()`), whichever proves to work — verify rather than assume.

- [ ] **Step 5: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgent/PaneWorkspaceView.swift \
        macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): the composer wears the pane's colour and always holds the caret

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 10: Rebuild and verify by eye

**Files:** none — this task produces a running app and a report, not a diff.

- [ ] **Step 1: Rebuild and install**

```bash
./scripts/rebuild-app.sh --no-notarize
```

This quits the running `/Applications/OmniAgent.app`, replaces it, and stops the PTY daemon with it. Expected and pre-authorised.

- [ ] **Step 2: Confirm it relaunched**

```bash
pgrep -x OmniAgent || open -a OmniAgent
```

`rebuild-app.sh` can skip its relaunch step and still report success.

- [ ] **Step 3: Report what needs a human eye**

There is no Screen Recording permission on this machine, so `screencapture` silently omits app windows. **Do not attempt screenshots and do not claim visual confirmation.** Report which of these remain unverified and belong to Bruno:

- the ground gradient reading as its own surface rather than terminal black
- the user bubble / agent-on-ground contrast at a real column width
- avatars appearing once per run and the gutter alignment holding
- the stats bar's glass matching the composer's
- the arrival animation reading as smooth rather than janky
- the pane-colour glow at a real `/color` setting

---

## Deferred, with reasons

- **Real token streaming** — the transcript JSONL only gains complete rows; needs a transport change.
- **Multi-line composer** — the PTY takes one line per send.
- **Voice input** — nothing in this repo does speech-to-text.
- **`accessibilityPerformPress` on work groups and system chips** — carried from the previous pass, still outstanding; VoiceOver can read expansion state but not toggle it.
- **Moving `MarkdownBlock` out of `PaneAppView.swift`** — a pure relocation with no behaviour change; not worth the diff while the file is being actively edited.
