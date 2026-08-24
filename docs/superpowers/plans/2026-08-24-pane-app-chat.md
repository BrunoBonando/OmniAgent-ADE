# Pane App View Chat Surface — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `PaneAppView` from a flat transcript dump into a native chat surface with the visual quality of the Claude desktop app.

**Architecture:** Four layers over the existing transcript reader, three of them pure functions with no AppKit dependency: `TranscriptTurn` merges consecutive same-role JSONL rows into turns; `MarkdownBlock` scans a turn's raw text into paragraph/heading/list/code/table blocks; runs of consecutive tool calls collapse into an expandable work group; the composer becomes a liquid-glass overlay the transcript scrolls behind. `ClaudeTranscriptReader`, the PTY transport, and Terminal view are not touched.

**Tech Stack:** Swift, AppKit (`NSStackView`, `NSTextField`, `NSVisualEffectView`), XCTest. Xcode-only build — no Rust toolchain needed.

**Spec:** `docs/superpowers/specs/2026-08-24-pane-app-chat-design.md`

## Global Constraints

- **Native AppKit only.** The `WKWebView` exception in `CLAUDE.md` covers the editor pane's internals and nothing else. No web views here.
- **No new files.** `TranscriptTurn` goes in `ClaudeTranscript.swift`; `MarkdownBlock` and all view helpers go in `PaneAppView.swift`. Both files are already in `macos/OmniAgent.xcodeproj`, so no `project.pbxproj` edits — and `project.pbxproj` is currently dirty from other work, so do not touch it.
- **`ClaudeTranscriptReader`'s parsing is not modified.** Adding a `TranscriptTurn` struct to the same file is fine; changing `decode`, `blocks(from:)`, `toolDetail(from:)` or `poll()` is not.
- **No changes to transport, PTY, `PaneWorkspaceView` framing, `PaneApprovalBarView`, or Terminal view.**
- **Colors and fonts come from `ShellPalette` and `ShellFont` only.** No raw `NSColor(red:...)` literals.
- **Shared working tree.** Other Claude sessions are editing this repo concurrently. Stage only the exact files each task names — never `git add -A`, never `git stash`.
- **Commit trailer** on every commit: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`

**Test commands.** Full suite (required before every commit):

```bash
caffeinate -disu ./macos/build.sh test
```

Single test while iterating (`build.sh` has no filter flag, so call `xcodebuild` directly):

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests/testNameHere 2>&1 | tail -20
```

`caffeinate -disu` is mandatory — the suite hangs if the display sleeps, and `-di` alone is not enough.

---

### Task 1: Collapse multi-line tool detail to one line

A `Bash` tool call's `command` is frequently a multi-line script. `toolLabel` sets `maximumNumberOfLines = 1` but not `usesSingleLineMode`, so hard newlines inside the string still break across lines — one tool call spilling twenty lines into the transcript. This is the single largest source of visual noise in the current view and the smallest fix in the plan.

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (`toolLabel`, ~line 453)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PaneAppView.toolLabel(name:detail:) -> NSTextField` becomes `static` (internal) instead of `fileprivate`, so tests can call it directly. Later tasks call it unchanged.

- [ ] **Step 1: Write the failing test**

Add to `PaneAppViewTests.swift`, in a new `// MARK: - Tool labels` section:

```swift
/// A `Bash` command is routinely a multi-line script. The tool line is a
/// line to skim, not a script to read: however many newlines the detail
/// carries, the label stays exactly one line tall.
func testToolLabelStaysOneLineForAMultiLineCommand() {
    let single = PaneAppView.toolLabel(name: "Bash", detail: "echo one")
    let multi = PaneAppView.toolLabel(
        name: "Bash",
        detail: "echo one\necho two\necho three\necho four"
    )
    XCTAssertEqual(
        multi.intrinsicContentSize.height,
        single.intrinsicContentSize.height,
        accuracy: 0.5
    )
}
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests/testToolLabelStaysOneLineForAMultiLineCommand 2>&1 | tail -20
```

Expected: a compile error first — `toolLabel` is `fileprivate`, and `@testable import` only opens up `internal`. Widen it in Step 3 and the test then fails on the height assertion (multi is ~4× taller).

- [ ] **Step 3: Make it pass**

In `PaneAppView.swift`, change the declaration from `fileprivate static func toolLabel` to `static func toolLabel`, and add one line to its body next to `maximumNumberOfLines`:

```swift
    /// The `▸ name  detail` line a tool call renders as — no box, no fill,
    /// truncated at the tail rather than wrapped, since a long shell command
    /// is a line to skim, not read in full.
    ///
    /// Internal rather than `fileprivate` so `PaneAppViewTests` can measure
    /// the label directly.
    static func toolLabel(name: String, detail: String) -> NSTextField {
        let text = detail.isEmpty ? "▸ \(name)" : "▸ \(name)  \(detail)"
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 1
        // `maximumNumberOfLines` caps *wrapping*; a hard newline inside a
        // `Bash` command still breaks the line without this, which is how one
        // tool call used to spill twenty lines into the transcript.
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = ShellFont.ui(12)
        field.textColor = ShellPalette.inkMuted
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
```

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all tests pass. `testRowsRenderRoleLabelsAndToolBlockContent` still passes — it asserts on `stringValue`, which is unchanged.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "fix(macos): a multi-line Bash command stops spilling down the App view

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Group consecutive same-role rows into turns

Claude Code writes each `tool_use` as its own assistant row, so one reply currently stamps `Claude` six times down the transcript. Merging consecutive same-role rows into a turn gives one role label per reply.

**Files:**
- Modify: `macos/OmniAgent/ClaudeTranscript.swift` (append `TranscriptTurn` at end of file — do not touch `ClaudeTranscriptReader`)
- Modify: `macos/OmniAgent/PaneAppView.swift` (`appendMessages`, `clearMessages`, `PaneAppMessageRowView.init`)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `TranscriptMessage`, `TranscriptBlock` from `ClaudeTranscript.swift` (unchanged).
- Produces:
  - `struct TranscriptTurn: Equatable { let id: String; let isUser: Bool; var blocks: [TranscriptBlock] }`
  - `static func TranscriptTurn.group(_ messages: [TranscriptMessage]) -> [TranscriptTurn]`
  - `@discardableResult static func TranscriptTurn.append(_ messages: [TranscriptMessage], to turns: inout [TranscriptTurn]) -> Int` — returns the index of the first turn changed, or `turns.count` when nothing was appended.
  - `PaneAppMessageRowView.init(turn: TranscriptTurn)` replaces `init(message:)`. Tasks 4 and 5 both build on this initializer.

- [ ] **Step 1: Write the failing tests**

Add to `PaneAppViewTests.swift` in a new `// MARK: - Turns` section:

```swift
/// One reply arrives as several assistant rows — Claude Code writes each
/// tool call as its own. They are one turn, and get one role label.
func testGroupMergesConsecutiveSameRoleMessages() {
    let turns = TranscriptTurn.group([
        TranscriptMessage(id: "1", isUser: true, blocks: [.text("hi")]),
        TranscriptMessage(id: "2", isUser: false, blocks: [.text("on it")]),
        TranscriptMessage(id: "3", isUser: false, blocks: [.tool(name: "Bash", detail: "ls")]),
        TranscriptMessage(id: "4", isUser: false, blocks: [.text("done")]),
    ])

    XCTAssertEqual(turns.count, 2)
    XCTAssertTrue(turns[0].isUser)
    XCTAssertEqual(turns[1].id, "2", "a turn keeps its first message's id")
    XCTAssertEqual(turns[1].blocks.count, 3, "blocks concatenate in order")
    XCTAssertEqual(turns[1].blocks.first, .text("on it"))
}

/// A poll landing another assistant row extends the turn already on screen
/// rather than opening a second one — and says which turn to redraw.
func testAppendExtendsTheLastTurnWhenTheRoleMatches() {
    var turns = TranscriptTurn.group([
        TranscriptMessage(id: "1", isUser: false, blocks: [.text("a")]),
    ])
    let changed = TranscriptTurn.append(
        [TranscriptMessage(id: "2", isUser: false, blocks: [.text("b")])],
        to: &turns
    )

    XCTAssertEqual(turns.count, 1)
    XCTAssertEqual(turns[0].blocks.count, 2)
    XCTAssertEqual(changed, 0)
}

/// A role flip opens a new turn, and only that new turn needs drawing.
func testAppendOpensANewTurnWhenTheRoleFlips() {
    var turns = TranscriptTurn.group([
        TranscriptMessage(id: "1", isUser: false, blocks: [.text("a")]),
    ])
    let changed = TranscriptTurn.append(
        [TranscriptMessage(id: "2", isUser: true, blocks: [.text("b")])],
        to: &turns
    )

    XCTAssertEqual(turns.count, 2)
    XCTAssertEqual(changed, 1)
}

/// The view stamps one role label per turn, not one per row.
func testOneRoleLabelPerTurn() {
    let view = makeView()
    view.appendMessages([
        TranscriptMessage(id: "1", isUser: false, blocks: [.text("on it")]),
        TranscriptMessage(id: "2", isUser: false, blocks: [.tool(name: "Bash", detail: "ls")]),
        TranscriptMessage(id: "3", isUser: false, blocks: [.tool(name: "Read", detail: "/x")]),
    ])

    let rows = view.descendants(PaneAppMessageRowView.self)
    XCTAssertEqual(rows.count, 1)
    let labels = view.descendants(NSTextField.self).filter { $0.stringValue == "Claude" }
    XCTAssertEqual(labels.count, 1)
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests 2>&1 | tail -20
```

Expected: compile failure — `TranscriptTurn` does not exist.

- [ ] **Step 3: Add `TranscriptTurn`**

Append to the end of `macos/OmniAgent/ClaudeTranscript.swift`:

```swift
/// One conversational turn: the consecutive `TranscriptMessage`s of a single
/// role, merged.
///
/// The merge exists because Claude Code writes each `tool_use` as its own
/// assistant row, so one reply arrives as several rows and a view drawing a
/// role label per row stamps "Claude" six times down a single answer.
struct TranscriptTurn: Equatable {
    /// The first merged message's id — stable for as long as the turn grows.
    let id: String
    let isUser: Bool
    var blocks: [TranscriptBlock]

    static func group(_ messages: [TranscriptMessage]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        append(messages, to: &turns)
        return turns
    }

    /// Merges `messages` into `turns`, extending the last turn whenever the
    /// role matches and opening a new one when it flips.
    ///
    /// Returns the index of the first turn this changed, so a caller holding
    /// one view per turn redraws from there instead of rebuilding the whole
    /// conversation. `turns.count` when `messages` was empty — a valid
    /// "nothing from here on" for the caller's loop.
    @discardableResult
    static func append(_ messages: [TranscriptMessage], to turns: inout [TranscriptTurn]) -> Int {
        var firstChanged = turns.count
        for message in messages {
            if let last = turns.last, last.isUser == message.isUser {
                turns[turns.count - 1].blocks.append(contentsOf: message.blocks)
            } else {
                turns.append(
                    TranscriptTurn(id: message.id, isUser: message.isUser, blocks: message.blocks)
                )
            }
            firstChanged = min(firstChanged, turns.count - 1)
        }
        return firstChanged
    }
}
```

- [ ] **Step 4: Make the view draw turns**

In `PaneAppView.swift`, add a stored property next to `reader`/`pollTimer`:

```swift
    /// The conversation as turns, mirroring `messageStack`'s arranged
    /// subviews one-for-one. Held because a turn *grows*: a poll landing
    /// another assistant row extends the last turn, and its row view has to
    /// be rebuilt from the merged blocks rather than appended beside.
    private var turns: [TranscriptTurn] = []
```

Replace the body of `appendMessages` (keeping its existing doc comment, and appending the paragraph below to it):

```swift
    /// …
    /// Rows are per *turn*, not per message, so a message that extends the
    /// turn already on screen rebuilds that one row rather than adding one.
    func appendMessages(_ messages: [TranscriptMessage]) {
        guard !messages.isEmpty else { return }
        // Measured before a single row is added: a user already scrolled up
        // to read earlier messages must not be yanked back down by a reply
        // arriving behind their back.
        let wasAtBottom = isScrolledToBottom()

        let firstChanged = TranscriptTurn.append(messages, to: &turns)
        // Everything from the first changed turn onwards is redrawn. In
        // practice that is one row: a poll either extends the last turn or
        // opens one.
        while messageStack.arrangedSubviews.count > firstChanged,
              let row = messageStack.arrangedSubviews.last {
            messageStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for turn in turns[firstChanged...] {
            let row = PaneAppMessageRowView(turn: turn)
            messageStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: messageStack.widthAnchor).isActive = true
        }

        emptyStateLabel.isHidden = true
        // Forced unconditionally, not just when scrolling: `messageStack`'s
        // height must be current the *next* time this runs too, and a user
        // scrolled up (who skips the `scrollToBottom()` below) would
        // otherwise leave it stale until AppKit's own next display pass.
        layoutSubtreeIfNeeded()
        if wasAtBottom {
            scrollToBottom()
        }
    }
```

Add one line to `clearMessages()`, immediately before its `for row in ...` loop:

```swift
        turns = []
```

Finally, in `PaneAppMessageRowView`, change the initializer signature and the two places it reads the message:

```swift
    init(turn: TranscriptTurn) {
```

```swift
        let roleLabel = ShellFont.label(
            turn.isUser ? "You" : "Claude",
            font: ShellFont.ui(11, .semibold),
            color: turn.isUser ? ShellPalette.inkTertiary : ShellPalette.accent
        )
```

```swift
        for block in turn.blocks {
```

Update its doc comment from `One `TranscriptMessage`` to `One `TranscriptTurn``.

- [ ] **Step 5: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all pass. Note that `testRowsRenderRoleLabelsAndToolBlockContent` still expects 2 rows for a user message followed by an assistant message — two roles, two turns — so it is unaffected.

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/ClaudeTranscript.swift macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): the App view labels a turn once instead of once per tool call

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Scan raw text into markdown blocks

`splitFences` splits a `.text` block into prose and code only, so headings, lists and tables all render as literal lines of proportional text — which is why a markdown table shows up as raw pipes. This generalizes the splitter into a block scanner. Rendering comes in Task 4; this task changes what the scanner *returns* and keeps the existing prose/code rendering working through it.

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (replace `PaneAppTextSegment` and `splitFences`; adjust `PaneAppMessageRowView.blockViews`)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `enum MarkdownBlock: Equatable` with cases `.paragraph(String)`, `.heading(level: Int, text: String)`, `.list(items: [String], ordered: Bool)`, `.code(String)`, `.table(header: [String], rows: [[String]])`
  - `static func MarkdownBlock.parse(_ text: String) -> [MarkdownBlock]`
  - `static func MarkdownBlock.cells(_ line: String) -> [String]` — splits one `|`-delimited row; Task 4's renderer does not need it, but the table tests do.
  - `PaneAppTextSegment` and `PaneAppView.splitFences` are **deleted**. Any existing test referencing them is rewritten in Step 1.

- [ ] **Step 1: Write the failing tests**

First, delete the existing fence-splitter tests. Find them in `PaneAppViewTests.swift` (they call `PaneAppView.splitFences` and assert on `PaneAppTextSegment`) and remove them — the cases below cover the same ground against the new API.

Then add a `// MARK: - Markdown blocks` section:

```swift
func testParseSplitsFencedCodeFromProse() {
    let blocks = MarkdownBlock.parse("before\n```\nlet x = 1\n```\nafter")
    XCTAssertEqual(blocks, [
        .paragraph("before"),
        .code("let x = 1"),
        .paragraph("after"),
    ])
}

/// A reply still being written ends mid-fence every time it is polled. An
/// unterminated fence runs to the end rather than being treated as an error.
func testParseLetsAnUnterminatedFenceRunToTheEnd() {
    let blocks = MarkdownBlock.parse("intro\n```\nstill typing")
    XCTAssertEqual(blocks, [.paragraph("intro"), .code("still typing")])
}

func testParseReadsHeadingsAndTheirLevel() {
    let blocks = MarkdownBlock.parse("## Results\ntext")
    XCTAssertEqual(blocks, [.heading(level: 2, text: "Results"), .paragraph("text")])
}

func testParseGroupsListItems() {
    let blocks = MarkdownBlock.parse("- one\n- two\n\nafter")
    XCTAssertEqual(blocks, [
        .list(items: ["one", "two"], ordered: false),
        .paragraph("after"),
    ])
}

func testParseReadsAnOrderedList() {
    let blocks = MarkdownBlock.parse("1. first\n2. second")
    XCTAssertEqual(blocks, [.list(items: ["first", "second"], ordered: true)])
}

/// The shape that reads as raw pipes today — note the empty leading header
/// cell, which is exactly what a `wc -l` table produces.
func testParseReadsATable() {
    let blocks = MarkdownBlock.parse("| | lines |\n|---|---|\n| Swift | 69158 |")
    XCTAssertEqual(blocks, [
        .table(header: ["", "lines"], rows: [["Swift", "69158"]]),
    ])
}

/// Ragged rows are ordinary markdown and stay a table — Task 4's renderer
/// pads them. Only a missing delimiter row disqualifies one.
func testParseKeepsARaggedTable() {
    let blocks = MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 |")
    XCTAssertEqual(blocks, [.table(header: ["a", "b"], rows: [["1"]])])
}

/// Pipe lines with no delimiter row are not a table. They fall back to the
/// paragraph they came from — losing formatting beats losing content.
func testParsePipeLinesWithoutADelimiterStayProse() {
    let blocks = MarkdownBlock.parse("| a | b |\n| 1 | 2 |")
    XCTAssertEqual(blocks, [.paragraph("| a | b |\n| 1 | 2 |")])
}

func testParseKeepsBlocksInOrder() {
    let blocks = MarkdownBlock.parse("# Title\npara\n- item\n```\ncode\n```")
    XCTAssertEqual(blocks, [
        .heading(level: 1, text: "Title"),
        .paragraph("para"),
        .list(items: ["item"], ordered: false),
        .code("code"),
    ])
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests 2>&1 | tail -20
```

Expected: compile failure — `MarkdownBlock` does not exist.

- [ ] **Step 3: Replace `PaneAppTextSegment` with `MarkdownBlock`**

At the top of `PaneAppView.swift`, replace the `PaneAppTextSegment` enum entirely with:

```swift
/// One block of a `.text` block's raw string — see `MarkdownBlock.parse`.
/// Internal rather than `private` so `PaneAppViewTests` can assert on a parse
/// directly, without going through a live row.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [String], ordered: Bool)
    case code(String)
    case table(header: [String], rows: [[String]])

    /// Splits raw assistant text into blocks by scanning it a line at a time.
    ///
    /// A line scanner, not a markdown parser: a line's prefix decides its
    /// block and consecutive lines of a kind accumulate. Deliberately
    /// forgiving, because this runs against a reply another process is still
    /// writing — an unterminated fence runs to the end, and anything that
    /// fails to be a table falls back to the prose it came from rather than
    /// being dropped.
    ///
    /// Inline emphasis inside a block is left to
    /// `PaneAppView.attributedMarkdown`; block structure is this function's
    /// job alone.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var items: [String] = []
        var ordered = false
        var pipes: [String] = []
        var inFence = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            blocks.append(.paragraph(joined))
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items: items, ordered: ordered))
            items = []
        }
        func flushPipes() {
            guard !pipes.isEmpty else { return }
            blocks.append(table(from: pipes) ?? .paragraph(pipes.joined(separator: "\n")))
            pipes = []
        }
        // Only ever called from a branch that is not itself accumulating, so
        // the fixed order here can never reorder two live accumulators.
        func flushAll() {
            flushParagraph()
            flushList()
            flushPipes()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushAll()
                }
                inFence.toggle()
                continue
            }
            if inFence {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(from: trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if let item = listItem(from: trimmed) {
                flushParagraph()
                flushPipes()
                // A bullet list running straight into a numbered one is two
                // lists, not one with a confused marker.
                if !items.isEmpty, ordered != item.ordered { flushList() }
                ordered = item.ordered
                items.append(item.text)
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushList()
                pipes.append(trimmed)
                continue
            }
            flushList()
            flushPipes()
            paragraph.append(line)
        }

        if inFence {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// The cells of one `|`-delimited row, outer pipes dropped and each cell
    /// trimmed. Internal so the table tests can build expectations with it.
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A run of pipe lines as a table, or nil when it is not one.
    ///
    /// The delimiter row is what decides it: markdown requires `|---|---|`
    /// under the header, and prose can easily contain pipe characters. Ragged
    /// body rows are *not* disqualifying — they are ordinary markdown, and
    /// `PaneAppView.renderTable` pads them.
    private static func table(from lines: [String]) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        let delimiter = cells(lines[1])
        guard !delimiter.isEmpty,
              delimiter.allSatisfy({ cell in
                  !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
              })
        else { return nil }
        return .table(
            header: cells(lines[0]),
            rows: lines.dropFirst(2).map { cells($0) }
        )
    }

    private static func heading(from trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count),
              trimmed.dropFirst(hashes.count).hasPrefix(" ")
        else { return nil }
        return .heading(
            level: hashes.count,
            text: String(trimmed.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func listItem(from trimmed: String) -> (text: String, ordered: Bool)? {
        for marker in ["- ", "* "] where trimmed.hasPrefix(marker) {
            return (String(trimmed.dropFirst(marker.count)), false)
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (String(trimmed.dropFirst(digits.count + 2)), true)
    }
}
```

Then delete `PaneAppView.splitFences` entirely, and point `PaneAppMessageRowView.blockViews` at the new API. Table, heading and list rendering land in Task 4 — until then they route through the existing prose and code views so nothing regresses:

```swift
    private static func blockViews(for block: TranscriptBlock) -> [NSView] {
        switch block {
        case .text(let text):
            return MarkdownBlock.parse(text).map { markdown -> NSView in
                switch markdown {
                case .paragraph(let prose):
                    return PaneAppView.proseLabel(prose)
                case .heading(_, let text):
                    return PaneAppView.proseLabel(text)
                case .list(let items, _):
                    return PaneAppView.proseLabel(items.joined(separator: "\n"))
                case .code(let code):
                    return PaneAppView.codeBlockView(code)
                case .table(let header, let rows):
                    return PaneAppView.codeBlockView(
                        ([header] + rows).map { $0.joined(separator: "  ") }.joined(separator: "\n")
                    )
                }
            }
        case .tool(let name, let detail):
            return [PaneAppView.toolLabel(name: name, detail: detail)]
        }
    }
```

Note that `parse` already discards empty paragraphs, so the `compactMap` and the emptiness check the old code needed are gone.

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all pass. If a test outside `PaneAppViewTests` referenced `PaneAppTextSegment`, it fails to compile — update it to `MarkdownBlock` rather than restoring the old enum.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): scan assistant text into markdown blocks, not just fences

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Render headings, lists and tables as themselves

Task 3 routes every block through prose or code views. This gives each its own rendering, including the padded-monospace table that reads like the terminal's.

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (add `renderTable`, `headingLabel`, `listView`; rewrite `blockViews`)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `MarkdownBlock` and its cases from Task 3; `PaneAppMessageRowView.init(turn:)` from Task 2.
- Produces:
  - `static func PaneAppView.renderTable(header: [String], rows: [[String]]) -> String`
  - `static func PaneAppView.headingLabel(level: Int, text: String) -> NSTextField`
  - `static func PaneAppView.listView(items: [String], ordered: Bool) -> NSView`

- [ ] **Step 1: Write the failing tests**

```swift
/// Columns pad to their widest cell, header included, so the table lines up
/// the way the terminal's does. A rule row separates header from body.
func testRenderTablePadsColumnsToTheirWidestCell() {
    let rendered = PaneAppView.renderTable(
        header: ["", "lines"],
        rows: [["Swift", "69158"], ["CSS", "9726"]]
    )
    let lines = rendered.components(separatedBy: "\n")

    XCTAssertEqual(lines.count, 4)
    XCTAssertEqual(lines[0], "       lines")
    XCTAssertTrue(lines[1].hasPrefix("─────"))
    XCTAssertEqual(lines[2], "Swift  69158")
    XCTAssertEqual(lines[3], "CSS    9726")
}

/// A ragged row is padded out to the table's column count rather than
/// throwing the alignment off or crashing on a missing index.
func testRenderTablePadsARaggedRow() {
    let rendered = PaneAppView.renderTable(header: ["a", "b"], rows: [["1"]])
    let lines = rendered.components(separatedBy: "\n")

    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(lines[2], "1")
}

/// A table reaches the row as one monospaced card, not as prose.
func testATableRendersAsAMonospacedBlock() {
    let row = PaneAppMessageRowView(turn: TranscriptTurn(
        id: "1",
        isUser: false,
        blocks: [.text("| a | b |\n|---|---|\n| 1 | 2 |")]
    ))
    let monospaced = row.descendants(NSTextField.self).filter {
        $0.font?.fontName == ShellFont.mono(12).fontName
    }

    XCTAssertEqual(monospaced.count, 1)
    XCTAssertTrue(monospaced[0].stringValue.contains("─"))
}

/// A heading is visibly bigger than body prose — the difference a reader
/// scans by.
func testAHeadingIsLargerThanBodyProse() {
    let heading = PaneAppView.headingLabel(level: 2, text: "Results")
    let prose = PaneAppView.proseLabel("Results")
    let headingSize = heading.font?.pointSize ?? 0
    let proseSize = prose.font?.pointSize ?? 0

    XCTAssertGreaterThan(headingSize, proseSize)
    XCTAssertEqual(heading.stringValue, "Results")
}

/// List items get their marker and stay one view per item, so a long item
/// wraps under its own bullet instead of under the one above.
func testAListRendersOneMarkedRowPerItem() {
    let list = PaneAppView.listView(items: ["one", "two"], ordered: false)
    let labels = list.descendants(NSTextField.self)

    XCTAssertEqual(labels.count, 4, "a marker and a body label per item")
    XCTAssertEqual(labels[0].stringValue, "•")
    XCTAssertEqual(labels[1].stringValue, "one")
}

func testAnOrderedListNumbersItsItems() {
    let list = PaneAppView.listView(items: ["one", "two"], ordered: true)
    let labels = list.descendants(NSTextField.self)

    XCTAssertEqual(labels[0].stringValue, "1.")
    XCTAssertEqual(labels[2].stringValue, "2.")
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests 2>&1 | tail -20
```

Expected: compile failure — `renderTable`, `headingLabel` and `listView` do not exist.

- [ ] **Step 3: Add the three renderers**

Add to `PaneAppView`'s `// MARK: - Block views` section:

```swift
    /// A markdown table as one monospaced, column-padded string — the same
    /// shape the terminal draws, and drawn into the same card a fenced code
    /// block gets.
    ///
    /// Deliberately not `NSGridView`/`NSTableView`: those are an order of
    /// magnitude more code, they have to negotiate width with the enclosing
    /// stack (a fight `codeBlockView`'s width constraint already documents),
    /// and they buy selectable cells nobody asked for.
    static func renderTable(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        guard columns > 0 else { return "" }

        // Ragged rows are ordinary markdown; they are padded out rather than
        // rejected, so a short row cannot index past a column width below.
        let padded = all.map { row in
            row + Array(repeating: "", count: columns - row.count)
        }
        var widths = Array(repeating: 0, count: columns)
        for row in padded {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }

        // Not `String.padding(toLength:)`: that counts UTF-16 units while
        // `cell.count` counts characters, and the two disagree the moment a
        // cell contains an emoji or a combining mark.
        func pad(_ cell: String, to width: Int) -> String {
            cell + String(repeating: " ", count: max(0, width - cell.count))
        }
        func line(_ row: [String]) -> String {
            row.enumerated()
                .map { pad($0.element, to: widths[$0.offset]) }
                .joined(separator: "  ")
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }

        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
        return ([line(padded[0]), rule] + padded.dropFirst().map(line))
            .joined(separator: "\n")
    }

    /// A heading: body prose, scaled up and weighted by level. Levels below
    /// 3 flatten together — a transcript is not a document outline, and three
    /// distinguishable sizes is as far as the difference stays useful.
    static func headingLabel(level: Int, text: String) -> NSTextField {
        let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 15 : 13)
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.font = ShellFont.ui(size, .semibold)
        field.textColor = ShellPalette.ink
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A list: one row per item, marker in its own column so a wrapping item
    /// hangs under itself rather than under the marker above it.
    static func listView(items: [String], ordered: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in items.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false

            let marker = ShellFont.label(
                ordered ? "\(index + 1)." : "•",
                font: ShellFont.ui(13),
                color: ShellPalette.inkTertiary
            )
            marker.setContentHuggingPriority(.required, for: .horizontal)
            let body = proseLabel(item)

            row.addArrangedSubview(marker)
            row.addArrangedSubview(body)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
```

Then rewrite `PaneAppMessageRowView.blockViews`'s `.text` case to use them:

```swift
        case .text(let text):
            return MarkdownBlock.parse(text).map { markdown -> NSView in
                switch markdown {
                case .paragraph(let prose):
                    return PaneAppView.proseLabel(prose)
                case .heading(let level, let text):
                    return PaneAppView.headingLabel(level: level, text: text)
                case .list(let items, let ordered):
                    return PaneAppView.listView(items: items, ordered: ordered)
                case .code(let code):
                    return PaneAppView.codeBlockView(code)
                case .table(let header, let rows):
                    return PaneAppView.codeBlockView(
                        PaneAppView.renderTable(header: header, rows: rows)
                    )
                }
            }
```

If `proseLabel` and `codeBlockView` are still `fileprivate`, widen both to `static` (internal) — the tests above call `proseLabel` directly.

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): headings, lists and aligned tables in the App view

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Collapse runs of tool calls into an expandable work group

A turn's tool calls are the work, not the answer. A run of consecutive `.tool` blocks collapses into one summary line that expands on click. Prose between runs stays where it is, so work still reads where it happened.

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (add `workSummary`, `PaneAppWorkGroupView`; rewrite `PaneAppMessageRowView.init`'s block loop)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: `TranscriptTurn` (Task 2), `PaneAppView.toolLabel` (Task 1), the block renderers (Task 4).
- Produces:
  - `static func PaneAppView.workSummary(for names: [String]) -> String`
  - `final class PaneAppWorkGroupView: NSView` with `init(calls: [(name: String, detail: String)])`, a `private(set) var isExpanded: Bool`, and `func toggle()`

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Work groups

func testWorkSummaryNamesASingleCall() {
    XCTAssertEqual(PaneAppView.workSummary(for: ["Bash"]), "Bash")
}

func testWorkSummaryCountsAHomogeneousRun() {
    XCTAssertEqual(PaneAppView.workSummary(for: ["Bash", "Bash", "Bash"]), "3 Bash calls")
}

/// Mixed runs get a neutral count — "3 Bash calls" would be a lie and
/// listing every name is the wall of text this exists to remove.
func testWorkSummaryFallsBackToStepsForAMixedRun() {
    XCTAssertEqual(PaneAppView.workSummary(for: ["Bash", "Read", "Edit"]), "3 steps")
}

/// Consecutive tool calls become one group, collapsed, with the detail
/// built but hidden — expansion must not have to re-derive anything.
func testConsecutiveToolCallsCollapseIntoOneGroup() {
    let row = PaneAppMessageRowView(turn: TranscriptTurn(id: "1", isUser: false, blocks: [
        .text("on it"),
        .tool(name: "Bash", detail: "ls"),
        .tool(name: "Bash", detail: "pwd"),
        .text("done"),
    ]))

    let groups = row.descendants(PaneAppWorkGroupView.self)
    XCTAssertEqual(groups.count, 1)
    XCTAssertFalse(groups[0].isExpanded)

    let summaries = row.descendants(NSTextField.self).filter { $0.stringValue == "2 Bash calls" }
    XCTAssertEqual(summaries.count, 1)
}

/// Prose on both sides of a run keeps its place — work reads where it
/// happened, rather than being hoisted to the top of the turn.
func testProseKeepsItsPlaceAroundAWorkGroup() {
    let row = PaneAppMessageRowView(turn: TranscriptTurn(id: "1", isUser: false, blocks: [
        .text("on it"),
        .tool(name: "Bash", detail: "ls"),
        .text("done"),
    ]))
    let body = row.descendants(NSStackView.self).first!
    let kinds = body.arrangedSubviews.map { $0 is PaneAppWorkGroupView }

    XCTAssertEqual(kinds, [false, false, true, false], "role label, prose, group, prose")
}

func testExpandingAWorkGroupRevealsItsCalls() {
    let group = PaneAppWorkGroupView(calls: [("Bash", "ls"), ("Bash", "pwd")])
    let detail = group.descendants(NSTextField.self).filter { $0.stringValue.hasPrefix("▸") }
    XCTAssertEqual(detail.count, 2, "detail is built up front, not on expand")

    group.toggle()

    XCTAssertTrue(group.isExpanded)
    XCTAssertFalse(detail[0].isHiddenOrHasHiddenAncestor)
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests 2>&1 | tail -20
```

Expected: compile failure — `workSummary` and `PaneAppWorkGroupView` do not exist.

- [ ] **Step 3: Add the summary and the view**

Add to `PaneAppView`'s `// MARK: - Block views` section:

```swift
    /// The header a collapsed run of tool calls reads as.
    ///
    /// A homogeneous run can name its tool honestly; a mixed one cannot, and
    /// listing every name would rebuild the wall of text this collapse
    /// exists to remove — so it counts steps instead.
    static func workSummary(for names: [String]) -> String {
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.allSatisfy({ $0 == first }) { return "\(names.count) \(first) calls" }
        return "\(names.count) steps"
    }
```

Add a new type at the end of `PaneAppView.swift`:

```swift
/// A run of consecutive tool calls in one turn, collapsed to a summary line
/// that expands on click.
///
/// The detail is built up front and merely hidden, never built on expand:
/// `PaneAppMessageRowView` lays a row out once and never rebuilds it, and
/// growing the view tree mid-scroll is exactly the kind of relayout that
/// contract exists to avoid.
final class PaneAppWorkGroupView: NSView {
    private(set) var isExpanded = false
    private let chevron: NSTextField
    private let detail = NSStackView()

    init(calls: [(name: String, detail: String)]) {
        chevron = ShellFont.label("⌄", font: ShellFont.ui(11), color: ShellPalette.inkFaint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let summary = ShellFont.label(
            PaneAppView.workSummary(for: calls.map(\.name)),
            font: ShellFont.ui(12),
            color: ShellPalette.inkMuted
        )

        let header = NSStackView(views: [chevron, summary])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 2
        detail.isHidden = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        for call in calls {
            let label = PaneAppView.toolLabel(name: call.name, detail: call.detail)
            detail.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }

        let body = NSStackView(views: [header, detail])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: body.widthAnchor),
            detail.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        header.addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func handleClick() { toggle() }

    /// Internal rather than private so the tests can drive expansion without
    /// synthesising a click.
    func toggle() {
        isExpanded.toggle()
        detail.isHidden = !isExpanded
        chevron.stringValue = isExpanded ? "⌃" : "⌄"
    }
}
```

- [ ] **Step 4: Fold runs into groups when a row is built**

In `PaneAppMessageRowView.init`, replace the `for block in turn.blocks` loop with a run-collecting pass:

```swift
        // Consecutive tool calls are one run and collapse together; anything
        // else flushes the run in progress first, so work keeps its place
        // between the prose either side of it.
        var run: [(name: String, detail: String)] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            add(PaneAppWorkGroupView(calls: run), to: body)
            run = []
        }
        for block in turn.blocks {
            switch block {
            case .tool(let name, let detail):
                run.append((name, detail))
            case .text(let text):
                flushRun()
                for view in Self.blockViews(for: .text(text)) { add(view, to: body) }
            }
        }
        flushRun()
```

and add the small helper it uses, as a private method on `PaneAppMessageRowView`:

```swift
    /// `.leading` alignment only pins each arranged view's leading edge;
    /// without the width constraint, a wrapping prose label or a truncating
    /// tool line reports its own tiny intrinsic width instead of filling the
    /// row.
    private func add(_ view: NSView, to body: NSStackView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
```

`blockViews`'s `.tool` case is now unreachable from this loop. Leave it — it is still the single definition of how one call renders, and `PaneAppWorkGroupView` calls `toolLabel` directly.

- [ ] **Step 5: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all pass. `testRowsRenderRoleLabelsAndToolBlockContent` asserts a tool label's text is present — it now lives inside a (hidden) work group, and `descendants` still finds it, so the assertion holds. If that test asserted on *visibility*, update it to expand the group first.

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): collapse a turn's tool calls into an expandable work group

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: Liquid-glass composer the transcript scrolls behind

The composer stops being a sibling below the scroll view and becomes an overlay floating above it, with the transcript scrolling behind the glass.

**Files:**
- Modify: `macos/OmniAgent/PaneAppView.swift` (constraints in `init`, add `composerGlass`, attach and send buttons, `insertAttachment(path:)`)
- Test: `macos/OmniAgentTests/PaneAppViewTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `PaneAppView.insertAttachment(path:)`; `scrollView` and `composerField` widened from `private` to `private(set)`/internal so the tests can measure them.

**Deliberate deviation from the spec:** the spec's composer row lists "attach, engine/model chips, send button". The chips are **not** built. The pane header already shows the engine and model chips two inches above the composer, so a second pair inside it is duplication — the reference image has them only because it is a standalone composer with no header. Attach and send are built.

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Composer

/// The transcript runs the full height of the view and scrolls *behind* the
/// composer, with enough bottom inset that the last message can clear the
/// glass instead of parking under it.
func testTranscriptScrollsBehindTheComposer() {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.scrollView.frame.height, view.frame.height, accuracy: 0.5)
    XCTAssertGreaterThan(view.scrollView.contentInsets.bottom, 40)
}

/// The glass is a real material, not a flat fill — it has to agree with the
/// approval card that can sit right above it.
func testTheComposerSitsOnGlass() {
    let view = makeView()
    let effects = view.descendants(NSVisualEffectView.self)

    XCTAssertEqual(effects.count, 1)
    XCTAssertEqual(effects[0].blendingMode, .withinWindow)
}

/// Attach puts the path into the draft, which is what the transport can
/// carry and what Claude Code already understands.
func testAttachInsertsThePathIntoTheDraft() {
    let view = makeView()
    view.composerField.stringValue = "look at"
    view.insertAttachment(path: "/tmp/a.swift")

    XCTAssertEqual(view.composerField.stringValue, "look at /tmp/a.swift")
}

func testAttachIntoAnEmptyDraftLeavesNoLeadingSpace() {
    let view = makeView()
    view.insertAttachment(path: "/tmp/a.swift")

    XCTAssertEqual(view.composerField.stringValue, "/tmp/a.swift")
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
caffeinate -disu xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -derivedDataPath macos/.build \
  -only-testing:OmniAgentTests/PaneAppViewTests 2>&1 | tail -20
```

Expected: compile failure — `scrollView` and `composerField` are `private`, `insertAttachment` does not exist.

- [ ] **Step 3: Make the composer an overlay**

In `PaneAppView`, widen the two properties the tests read:

```swift
    /// Internal rather than `private` so the composer-layout tests can
    /// measure the inset the glass overlay depends on. Still a `let` — only
    /// its visibility widens.
    let scrollView: ShellScrollView
```

```swift
    /// Internal rather than `private` so the composer tests can read and set
    /// the draft directly.
    let composerField: HomeComposerField = {
```

Add the glass and the two buttons as stored properties:

```swift
    /// `.withinWindow`, not `.behindWindow`: this overlay floats over the
    /// transcript inside the pane, so what it should sample is the content
    /// scrolling under it. `.behindWindow` — what `CommandPaletteController`
    /// uses, correctly, for its own window — would sample the desktop
    /// instead and show nothing of the conversation.
    private let composerGlass: NSVisualEffectView = {
        let effect = NSVisualEffectView()
        effect.material = .regular
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = ShellPalette.cardStroke.cgColor
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
    }()
```

In `init`, delete the `ShellSeparator` and rebuild the bottom of the view. Replace the `for view in [scrollView, emptyStateLabel, separator, fieldContainer]` loop and the whole `NSLayoutConstraint.activate` block with:

```swift
        let attachButton = Self.composerButton(symbol: "paperclip", accessibility: "Attach a file")
        attachButton.target = self
        attachButton.action = #selector(chooseAttachment)

        let sendButton = Self.composerButton(symbol: "arrow.up", accessibility: "Send")
        sendButton.target = self
        sendButton.action = #selector(submitComposer)

        let controls = NSStackView(views: [attachButton, NSView(), sendButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        composerGlass.addSubview(composerField)
        composerGlass.addSubview(controls)
        for view in [scrollView, emptyStateLabel, composerGlass] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            // Full height: the transcript scrolls *behind* the glass, and the
            // content inset below is what keeps the last message reachable.
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            composerGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composerGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composerGlass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            composerField.topAnchor.constraint(equalTo: composerGlass.topAnchor, constant: 12),
            composerField.leadingAnchor.constraint(equalTo: composerGlass.leadingAnchor, constant: 14),
            composerField.trailingAnchor.constraint(equalTo: composerGlass.trailingAnchor, constant: -14),

            controls.topAnchor.constraint(equalTo: composerField.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: composerGlass.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: composerGlass.trailingAnchor, constant: -10),
            controls.bottomAnchor.constraint(equalTo: composerGlass.bottomAnchor, constant: -10),
            controls.heightAnchor.constraint(equalToConstant: 26),
        ])

        // AppKit would otherwise fold its own automatic insets into these and
        // the inset would not match the glass.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            // Glass height (12 + field + 10 + 26 + 10) plus its 12pt margin,
            // so the last message scrolls clear rather than parking under it.
            bottom: Self.composerClearance,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -Self.composerClearance, right: 0)
```

Add the constant, the button factory and the attach handler:

```swift
    /// How much room the glass composer takes out of the transcript's scroll
    /// area — the overlay's own height plus its bottom margin.
    private static let composerClearance: CGFloat = 90

    private static func composerButton(symbol: String, accessibility: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibility
        )
        button.contentTintColor = ShellPalette.inkTertiary
        button.imageScaling = .scaleProportionallyDown
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertAttachment(path: url.path)
    }

    /// Puts a file's path into the draft. A path is what the transport can
    /// carry — the composer's text goes into a live PTY — and what Claude
    /// Code already knows how to open.
    func insertAttachment(path: String) {
        let draft = composerField.stringValue.trimmingCharacters(in: .whitespaces)
        composerField.stringValue = draft.isEmpty ? path : "\(draft) \(path)"
        window?.makeFirstResponder(composerField)
    }
```

Delete the now-unused `fieldContainer` property and its `onFocusChange` border handling — the glass has its own stroke. Keep `composerField.target`/`action`, and keep `submitComposer` as it is; the send button reuses it, which is why it must stay `@objc`.

- [ ] **Step 4: Run the full suite**

```bash
caffeinate -disu ./macos/build.sh test
```

Expected: all pass. Any existing test asserting on `fieldContainer` needs rewriting against `composerGlass` — do that rather than keeping the old container alive.

- [ ] **Step 5: Verify it visually**

Rebuild and look at a Claude pane in App mode:

```bash
./scripts/rebuild-app.sh --no-notarize
```

Confirm, by eye: transcript visible *through* the composer as it scrolls under it; the last message reachable above the glass; a collapsed work group expanding on click; a markdown table aligned in columns.

Check the app actually relaunched (`rebuild-app.sh` can skip that step and still report success):

```bash
pgrep -x OmniAgent || open -a OmniAgent
```

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/PaneAppView.swift macos/OmniAgentTests/PaneAppViewTests.swift
git commit -m "feat(macos): liquid-glass composer the App view transcript scrolls behind

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Deferred, with reasons

Named here so they are not silently lost, and so nobody adds them opportunistically mid-task:

- **Todo/plan cards** — need `TodoWrite` state read first. Additive once `MarkdownBlock` and turns exist.
- **Token-level streaming** — the transcript JSONL only gains complete rows. Needs a transport change; see the spec's "Transport" section.
- **Multi-line composer** — the PTY takes one line per send.
- **Voice input** — nothing in this repo does speech-to-text.
- **Engine/model chips in the composer** — the pane header already shows them (Task 6).
- **Duration on work-group headers** (`· 12s`) — the reader discards row timestamps; the count carries the information.
