# App view — a chat you actually want to read

Date: 2026-08-25
Status: proposed design, awaiting review
Builds on `docs/superpowers/specs/2026-08-24-pane-app-chat-design.md` (shipped:
turn grouping, markdown blocks, collapsed tool runs, glass composer, centred
880pt column).

## Goal

The App view now renders a readable transcript, but it still *looks* like a
terminal wearing a chat's clothes: black pane background, raw
`<task-notification>` blocks in the flow, no sense of who is speaking, and no
readout of what a conversation is costing. This pass makes it read as a chat —
ChatGPT's shape, WhatsApp's speaker grouping — on its own ground, with the
machinery folded away but never lost.

Bruno's framing, which the rest of this document serves: *"Design and ease of
use is very important. I'm a very visual person."*

## Non-goals

- **Real token streaming.** The transcript JSONL only ever gains complete rows;
  there are no tokens to stream. See "Arrival animation" for what is built
  instead, and why a fake typewriter is refused.
- **Changing the transport.** One `claude` TUI per pane, Terminal and App views
  on one session, exactly as today.
- **Touching Terminal view.** Its black background is correct — a terminal
  theme with any transparency washes its own text out.

---

## 1. Ground, not terminal black

`PaneContainerView.paneBackgroundColor` is `(12,12,15)` opaque, and
`PaneGroundView` — the workspace ground behind the grid — is a gradient from
`(36,38,45)` to `(15,16,20)`.

`PaneGroundView`'s own comment explains why panes paint opaque over it: *"a
terminal theme with any transparency washes its own text out."* That reason is
about the **terminal**. The App view has no terminal theme to protect, so it
takes the ground gradient. This is not an exception to the rule; it is the rule
no longer applying.

App mode paints the same two-stop gradient. Terminal mode is untouched.

## 2. Layout: ChatGPT's shape

Decided against WhatsApp-style bubbles on both sides: a wide table or code block
inside an agent bubble pushes it to nearly the full column, so the bubble stops
distinguishing anything exactly where answers are longest.

```
┌─ 880pt centred column ──────────────┐
│                    ╭─────────────╮  │
│                    │ How many    │  │
│                    │ lines?      │  │
│                    ╰─────────────╯  │
│                       Dev Mode ●    │
│                                     │
│  ◉  ~341k lines tracked             │
│     (excluding lockfiles).          │
│                                     │
│     ┌───────┬───────┐               │
│     │ lines │ files │               │
│     └───────┴───────┘               │
│                                     │
│     ▸ 3 Bash calls           ⌄      │
└─────────────────────────────────────┘
```

- **User turns**: a rounded bubble, right-aligned, with the user's avatar and
  name below/beside it.
- **Agent turns**: no bubble. Prose sits on the ground under the OmniAgent mark,
  left-aligned, indented to clear the avatar gutter.
- **One avatar per run of consecutive same-role turns.** `TranscriptTurn`
  already merges consecutive same-role rows, so this rule is a property of a
  type that exists — the avatar renders on the first turn of a run and is
  omitted on the rest, reappearing only after the other party speaks.

### Avatars

- **Agent**: `OmniAgentMark` — already in `Assets.xcassets`, already used by the
  home page's hero tile.
- **User**: labelled **Dev Mode**. A new imageset added *inside* the existing
  `Assets.xcassets` (which needs no `project.pbxproj` change), or
  `person.crop.circle.fill` if the supplied silhouette proves awkward at 28pt —
  the reference image is a generic silhouette and the SF Symbol is its
  equivalent. Implementer's call, recorded either way.

## 3. Parsers — allowlist only

Transcript prose contains machinery blocks. Measured across Bruno's 528 real
transcripts:

| block | occurrences |
|---|---|
| `<total_tokens>` | 8,328 |
| `<task-notification>` (with `summary`, `task-id`, `status`, `output-file`, `tool-use-id`, `usage`, `result`, `tool_uses`, `subagent_tokens`, `duration_ms`, `note`) | 966 |
| `<system-reminder>` | 278 |
| `<local-command-stdout>` | 171 |
| `<command-name>` / `<command-message>` / `<command-args>` | ~150 each |

**The trap, and the single most important constraint in this document.** The
same corpus contains `<string>` (501), `<private>` (364), `<group>` (320),
`<div>` (204), `<span>` (140), `<path>` (138) — all of them *content*: SVG,
HTML and plist inside code under discussion. A generic XML/tag matcher would
silently delete the user's own code from the transcript.

**Parsing runs off a fixed allowlist of known block names and nothing else.** A
tag not on the list is prose and stays prose, verbatim. This must be tested with
a fixture containing `<div>` and `<path>` in a code fence, asserting they
survive untouched.

### Rendering

A recognised block becomes a **collapsed chip in place**, at the point in the
conversation where it occurred — position is information a side panel would
throw away. Expanding reveals the parsed detail (monospace permitted inside;
see §6). `<total_tokens>` is not rendered inline at all: it is one live number,
and it belongs in the stats bar (§4).

## 4. The stats bar

Four readouts in one liquid-glass bar pinned below the pane header, over the
transcript.

| readout | source | scope |
|---|---|---|
| **Tokens** | sum of `input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens` across this pane's transcript | **this conversation** |
| **Context** | the latest assistant row's `input + cache_read + cache_creation` | **this conversation** |
| **Session** | `claude -p "/usage"` → `Current session: N% used · resets <time>` | account-global |
| **Week** | same → `Current week (all models): N% used · resets <date>` | account-global |

Explicitly **per conversation**, not per project and not per multi-terminal
session: the first two come from the pane's own transcript file.
`UsageAnalytics` is deliberately *not* used — it aggregates per project, which
is the wrong unit.

### The `/usage` poller

Verified working headlessly: `claude -p "/usage"` returns the limits as plain
text on the user's subscription, without touching any live conversation.

Two properties this forces:

- **Measuring usage consumes usage.** `/usage` is a real request against the
  same limits it reports. So: exactly **one app-wide poller** (the limits are
  account-global and identical in every pane), a cached last-known value, a
  refresh interval of minutes not seconds, and an explicit manual refresh.
  Eight panes each polling would be absurd and self-defeating.
- **It is slow** (seconds). Always a background fetch rendering a cached value;
  never a blocking read. A pane that has never seen a value shows the readout
  as pending rather than as zero.

### Narrow panes

Panes live in a grid and are often ~400pt wide, where four readouts crowd or
wrap. The bar renders all four when it fits, and otherwise keeps **Context**
(the only one that changes minute to minute) with the rest behind a tap. It
degrades rather than breaking, and reads as one object rather than four things
hovering.

A per-model weekly line (`Current week (Fable): 10% used`) is also present in
`/usage` output and is parsed for the expanded state, since it costs nothing
once the fetch exists.

## 5. Arrival animation

Real streaming is impossible here (see Non-goals). What is real: during a long
agentic turn, **rows genuinely arrive in batches** on the 0.3s poll.

Each newly appended turn — or newly appended block within a growing turn —
fades and rises in over ~200ms, respecting `ShellMotion.reduced`. This is not a
simulation: it reflects the true fact that content just arrived.

**A typewriter reveal on already-complete text is refused.** It looks like
streaming while deliberately withholding a finished answer so the user reads it
more slowly — the exact opposite of this redesign's purpose. If Bruno wants it
after seeing the fade, it is a small, separate change.

## 6. One font

Prose, headings and lists use `ShellFont.ui` at a constant size — the home
page's font, which the App view already uses for paragraphs.

Monospace is confined to three places and nowhere else: fenced code blocks,
rendered tables (alignment depends on it), and the inside of an expanded parser
chip. A collapsed chip's header is UI font like everything else.

## 7. The composer carries the pane's colour

A pane customised with Claude's `/color` exposes `descriptor.claudeColor`, which
the header already resolves to a swatch via
`PaneHeaderView.colorDotImage(for:)`.

The composer's focus glow and its resting stroke take that tint instead of the
fixed accent, so a pane the user coloured orange has an orange composer. Panes
with no colour keep today's blue→purple ramp. This needs a tint accessor
extracted from whatever `colorDotImage(for:)` already resolves, rather than a
second string→colour table.

`WorkspaceColor` (the eight workspace swatches, `WorkspaceCustomizations.swift`)
is a *different* concept — workspace customisation, not pane colour. Do not
conflate them.

## 8. Error handling

Consistent with the existing posture: the transcript is written concurrently, so
partial and malformed content is normal, never an error.

- An unrecognised or malformed system block renders as the prose it came from.
  Losing formatting beats losing content.
- A `/usage` fetch that fails, times out, or returns an unparseable shape leaves
  the last known value with a stale marker; it never blanks the bar and never
  surfaces an error dialog.
- A transcript row with no `usage` fields contributes zero rather than breaking
  the sum.

## 9. Testing

Pure functions, unit tested:

- the allowlist parser: each recognised block; **`<div>`/`<path>`/`<string>`
  inside a code fence surviving untouched** (the trap); a malformed block
  degrading to prose.
- `/usage` output parsing: the real format above, a per-model line, and a
  garbage input degrading safely.
- per-conversation token and context sums, including rows lacking `usage`.
- avatar-run grouping: avatar on the first turn of a run, absent on the rest,
  reappearing after the other party speaks.

Layout, by direct frame assertion (not screenshot): user bubble right-aligned
and agent content left-indented; the stats bar's narrow-pane collapse; the
composer tint following a coloured pane.

**Every layout test must be built with real content in it.** The last pass
shipped a column-width test that measured an empty stack and passed while the
app was visibly broken; an empty container proves nothing about a constraint
that only fails under content.

## 11. The composer takes focus, and the whole card is a target

Two behaviours, both about never making the user hunt for the cursor.

**The App view always lands focus in the composer.** `primaryResponderView`
already returns `composerField`, and `PaneWorkspaceView` makes it first
responder when a pane is focused — but that is one path. Focus must also land
after the pane is *moved*: dragged to a new grid position, re-split, restored
from a chip, or switched into App mode. Any transition that leaves this view on
screen and active ends with the composer as first responder.

The rule: if the App view is the pane's active content and the pane is focused,
the caret is in the composer. There is no state where it is visible, focused,
and typing goes nowhere.

**The whole glass card is a click target, and the caret goes to the end.** The
composer is now 107pt tall while the field itself is a single line near its top,
so most of the card is dead space that looks typable and is not. A click
anywhere in the card — padding, the controls row's empty stretch, below the
text — focuses the field and places the insertion point at the **end** of any
existing draft, never mid-word and never selecting it.

Excluded from that target: the attach and send buttons, which keep their own
click behaviour.

Tested by direct assertion: a click in the card's dead space leaves the field
first responder with `selectedRange` collapsed at the draft's length; a click on
the send button submits rather than focusing.

## 12. Deferred

- Real token streaming (transport change).
- Multi-line composer (the PTY takes one line per send).
- Voice input (no speech-to-text in this repo).
- `accessibilityPerformPress` on work groups — carried over, still outstanding.
