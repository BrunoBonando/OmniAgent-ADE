# Pane App View — a native chat surface you can live in

Date: 2026-08-24
Status: approved design, not yet planned
Supersedes nothing. Extends the App view delivered by
`.superpowers/sdd/is-it-possible-to-velvety-gray/` (Tasks 2–3).

## Goal

`PaneAppView` today renders a Claude pane's transcript as an undifferentiated
text dump: one role label per JSONL row, multi-line shell commands spilled
into the transcript, markdown tables printed as raw pipes. It reads worse
than the terminal it sits on top of.

This design makes it a chat surface with the visual quality of the Claude
desktop app — the surface Bruno works in day to day — while the terminal
stays available, unchanged, for people who prefer it.

## Non-goals

Explicitly out of scope for this pass. Each is additive afterwards, and none
is blocked by anything below.

- **Todo/plan cards.** Need `TodoWrite` state read first; additive once the
  block model exists.
- **Token-level streaming.** The transcript JSONL only gains complete rows,
  so text arrives per message, not per token. Changing that means changing
  transport — see "Transport".
- **Multi-line composer.** The transport takes one line per send; a composer
  that accepts newlines the PTY would submit early is a lie. Deferred with
  transport, not with styling.
- **Voice input.** Nothing in this repo does speech-to-text. A mic button
  that opens a permission prompt and does nothing is worse than no button.
- **Removing or changing Terminal view.** Untouched. Also gated separately by
  `scripts/cutover.sh` (0/2, CLOSED).

## Transport: unchanged, and deliberately so

Each pane runs exactly one `claude` TUI in `omniagent-pty-daemon`, as today.
Terminal view is that PTY verbatim; App view is a native chat over the same
session. One process, one conversation, one subscription.

Two alternatives were considered and rejected:

- **Headless `claude` with bidirectional `stream-json`.** Structurally the
  right way to build a desktop-class chat client — token streaming, tool
  events, permission requests and todo state all arrive as data instead of
  being parsed off a screen. Rejected because a headless pane is no longer a
  terminal: Terminal view for that pane would either disappear or require a
  *second* Claude process, i.e. a second conversation. Keeping both views on
  one session is a hard product requirement.
- **Status quo: parse everything off the terminal screen.** Rejected as the
  general strategy. `PaneApprovalBar` already carries the cost in a comment —
  *"measured against Claude Code 2.1.234"* — and that comment multiplies with
  every capability added.

**Neither this design nor either alternative calls the Anthropic API.**
`claude` headless is the same binary with the same login; the distinction is
whether it draws a TUI. Nothing in this repo injects an `ANTHROPIC_API_KEY`,
and `crates/omniagent-pty-daemon/src/session.rs:1130` asserts the daemon does
not treat one as inherited identity. The same holds for any other engine: we
drive its CLI, never its API.

**The adopted rule:** keystrokes *out* (text, `Esc`, `Shift-Tab`, digits) are
reliable and stay. State *in* comes from the transcript JSONL wherever a file
carries it, and from the screen only where no file does.

**Everything below is rendering and input inside `PaneAppView`.** No new
process, no protocol change, no change to `ClaudeTranscriptReader`'s parsing.

## Architecture

Four layers, three of them pure functions with no AppKit dependency:

```
ClaudeTranscriptReader        (unchanged)
  → [TranscriptMessage]        rows, each .text/.tool blocks
      ↓  TranscriptTurn.group  ← pure
  → [TranscriptTurn]           consecutive same-role rows merged
      ↓  MarkdownBlock.parse   ← pure
  → [MarkdownBlock]            paragraph/heading/list/code/table
      ↓  PaneAppMessageRowView
  → NSView tree
```

The reader is not touched. It is well-tested, it handles a file being written
concurrently, and none of this needs it to change. Block structure is a
*rendering* concern and is derived in the view layer, where `splitFences`
already lives.

### 1. `MarkdownBlock` — generalizing `splitFences`

`PaneAppTextSegment` (`.prose`/`.code`) becomes:

```swift
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [String], ordered: Bool)
    case code(String)
    case table(header: [String], rows: [[String]])
}
```

A line scanner, not a markdown parser: a line's prefix decides its block
(```` ``` ````, `#`, `- `/`* `/`1. `, `|`), consecutive lines of a kind
accumulate, anything else is paragraph text. Fence handling is what
`splitFences` already does and keeps its current semantics — marker lines
dropped, unterminated fence runs to the end rather than erroring.

Inline emphasis inside a block continues through `attributedMarkdown`
unchanged. `interpretedSyntax` stays `.inlineOnlyPreservingWhitespace`: block
structure is now this scanner's job, so asking Apple's parser for it as well
would fight it.

Rendering per case:

| case | view |
|---|---|
| `paragraph` | today's `proseLabel` |
| `heading` | `proseLabel` at a larger, semibold `ShellFont.ui` |
| `list` | one `proseLabel` per item, bullet/number glyph, leading indent |
| `code` | today's `codeBlockView`, unchanged |
| `table` | monospace, column-padded (below) |

### 2. Tables

Rendered as a single monospace string in the existing `codeBlockView` card:
each column padded to its widest cell, a rule row under the header. This is
what the terminal already does, and the terminal's table is the one Bruno
pointed at as looking right.

`NSGridView`/`NSTableView` are rejected: ~10× the code, a width negotiation
against the enclosing stack that `PaneAppView.swift:493` already documents
fighting, and selectable cells nobody asked for.

Pure function, `([String], [[String]]) -> String`, directly testable.

### 3. Turns, not rows

Claude Code writes each `tool_use` as its own assistant row, which is why the
current view stamps `Claude` six times for one reply.

```swift
struct TranscriptTurn: Equatable {
    let id: String        // first message's id
    let isUser: Bool
    let blocks: [TranscriptBlock]   // concatenated, order preserved
}
```

Consecutive messages of the same role merge into one turn. One role label per
turn.

Appending stays incremental: a new message whose role matches the last turn
extends it, otherwise it opens a new one. A turn that grows replaces its own
row view; a `didReset` clears everything, as today.

### 4. Collapsed work

Within a turn, a *run* of consecutive `.tool` blocks collapses into one
`WorkGroupView` — Bruno's reference image 3. Prose between runs stays in
place, so work still reads where it happened rather than being hoisted.

Header: the tool name when the run is homogeneous (`Ran 3 Bash commands`),
otherwise `3 steps`. Pure function, testable. No duration in v1 — the reader
discards row timestamps today and the count carries the information.

Collapsed by default. Expanding reveals the current `toolLabel` lines. Rows
are built once and never rebuilt (`PaneAppMessageRowView`'s existing
contract), so expansion toggles `isHidden` on an already-built detail stack
rather than re-deriving anything.

**Bug fixed here:** `toolLabel` sets `maximumNumberOfLines = 1` but not
`usesSingleLineMode`, so a `Bash` `command` containing newlines still breaks
across lines — the single largest source of noise in the current view. The
detail lines get `usesSingleLineMode = true`.

### 5. Liquid-glass composer

The composer stops being a sibling below the scroll view and becomes an
overlay floating above it. Transcript content scrolls *behind* it.

- `scrollView` fills the full view; the `ShellSeparator` above the composer is
  deleted.
- The composer sits in an `NSVisualEffectView`, `.regular` material — the same
  material `PaneAsk.swift:452` documents for the approval card, so the two
  agree when both are on screen.
- `scrollView.automaticallyAdjustsContentInsets = false`, and
  `contentInsets.bottom` = composer height + margin, so the last message can
  scroll clear of the glass instead of hiding under it.
- Bottom row inside the glass: attach, engine/model chips, send button — the
  arrangement of Bruno's reference image 5.
- **Attach** inserts the chosen file's path into the message text. That is
  what the transport can carry, and what Claude Code already understands.
- The field stays single-line and `usesSingleLineMode` (see Non-goals).

`PaneApprovalBarView` keeps its current position and behaviour, above the
composer. It works; nothing here rebuilds it.

## Data flow

Unchanged end to end. `isLive` starts a 0.3s poll; each poll appends decoded
messages or, on `didReset`, clears first. The only difference is that append
now merges into turns and derives blocks before building views.

Input is unchanged: `onSubmit` → `sendCommandClearingInput` → PTY.

## Error handling

The existing posture is correct and is preserved: a live file written by
another process means partial and malformed content is *normal*, never an
error. Extending that to the new layers:

- The block scanner never throws. A table with ragged rows is padded to its
  widest row rather than rejected — ragged rows are ordinary markdown. Only a
  run of `|` lines with no delimiter row under the header fails to be a table,
  and it renders as the paragraph text it came from rather than being dropped:
  losing content is worse than losing formatting.
- A tool run with zero renderable detail still shows its header; the group is
  never empty.
- `attributedMarkdown`'s existing `try?`-with-plain-text fallback stays.

## Testing

Three of the four layers are pure and get direct unit tests in
`PaneAppViewTests`:

- `MarkdownBlock.parse` — each block kind, fences (including unterminated),
  a table, a ragged table degrading to paragraph, mixed input.
- table renderer — column padding, a cell wider than its header, one column.
- work-group header — homogeneous run, mixed run, single call.
- `TranscriptTurn.group` — consecutive same-role merge, alternation,
  incremental append extending vs. opening a turn.

Layout is verified by rendering the view offscreen to a PNG from a test, the
convention already used in this repo for AppKit layout: composer overlay
position, content inset clearing the glass, a collapsed group's height, an
expanded group's height.

`toolLabel`'s newline collapse gets a regression test — it is a one-line fix
that silently regresses.

Full suite: `caffeinate -disu ./macos/build.sh test`.

## Staging

Each step is independently shippable and visible in a rebuild:

1. `usesSingleLineMode` fix + turn grouping — biggest visual gain, smallest diff.
2. `MarkdownBlock` + heading/list/table rendering.
3. Collapsed work groups.
4. Glass composer overlay + bottom row.
