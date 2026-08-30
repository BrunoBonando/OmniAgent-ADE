import Foundation

/// Mosh-style local echo for a remote terminal, as a pure value: every
/// printable keystroke the user sends is *predicted* at the cursor, and
/// every real `feed` is *reconciled* against those predictions cell by cell.
///
/// It never touches the terminal buffer. What it offers is `drawn` — the
/// predictions an overlay may paint above the real screen — and mosh's
/// confidence rule decides when that is non-empty: nothing is drawn until the
/// first prediction of a burst is confirmed by its real echo, so a password
/// prompt or vim's normal mode (which echo nothing, or something else) never
/// flashes text; once one keystroke has round-tripped, every following one
/// appears instantly. Any mismatch, control byte, escape sequence or a
/// prediction left unconfirmed for `timeout` drops everything and returns to
/// `.unknown`.
struct PredictiveEchoModel: Equatable {
    struct Prediction: Equatable {
        let row: Int
        let col: Int
        let character: Character
        let madeAt: TimeInterval
    }

    enum Confidence: Equatable { case unknown, confirmed }

    private(set) var confidence: Confidence = .unknown
    private(set) var pending: [Prediction] = []
    private var cursorRow = 0
    private var cursorCol = 0
    /// A prediction older than this without its echo resets the model.
    var timeout: TimeInterval = 1.0

    /// The predictions to paint: the pending ones, but only once confirmed.
    var drawn: [Prediction] { confidence == .confirmed ? pending : [] }

    /// Call with the real cursor before `predict` — it is taken only while
    /// nothing is pending, because while predictions are out the real cursor
    /// still sits where it was *before* them, and the predicted cursor is the
    /// one that has moved on.
    mutating func syncCursor(row: Int, col: Int) {
        guard pending.isEmpty else { return }
        cursorRow = row
        cursorCol = col
    }

    /// One keystroke as the bytes sent to the PTY: a single printable
    /// character advances the predicted cursor (wrapping at `cols`); a lone
    /// backspace undoes our own last prediction and nothing else; anything
    /// else — Enter, arrows, control keys, a paste of several characters —
    /// clears the model, because we cannot know what the program will do.
    mutating func predict(_ bytes: [UInt8], now: TimeInterval, cols: Int) {
        if bytes == [0x7f] || bytes == [0x08] {
            guard let last = pending.last,
                  (last.row == cursorRow && last.col == cursorCol - 1)
                      || (cursorCol == 0 && last.row == cursorRow - 1 && last.col == cols - 1)
            else { reset(); return }
            pending.removeLast()
            cursorRow = last.row
            cursorCol = last.col
            return
        }
        guard let scalar = String(decoding: bytes, as: UTF8.self).unicodeScalars.first,
              bytes.count == String(scalar).utf8.count,
              bytes.count <= 4,
              scalar.value >= 0x20,
              scalar.value != 0x7f,
              !(0x80...0x9f).contains(scalar.value)
        else { reset(); return }
        pending.append(Prediction(row: cursorRow, col: cursorCol, character: Character(scalar), madeAt: now))
        cursorCol += 1
        if cursorCol >= cols {
            cursorCol = 0
            cursorRow += 1
        }
    }

    /// After every real `feed`: `cellAt(row, col)` is the real character in
    /// a viewport cell, or `nil` for a cell that is out of range or still
    /// empty (the caller maps the terminal's empty-cell value to `nil`; a
    /// real space is a real echo and confirms a typed space). `nil` means the
    /// echo has not arrived — keep waiting; the right character confirms the
    /// prediction (and the model); a different one means the program did
    /// something else with the keystroke, so every prediction goes. The
    /// timeout is judged after the cells, so an echo that arrives late still
    /// confirms; only what is *still* unconfirmed past it resets the model.
    mutating func reconcile(now: TimeInterval, cellAt: (Int, Int) -> Character?) {
        while let first = pending.first {
            guard let real = cellAt(first.row, first.col) else { break }
            guard real == first.character else { reset(); return }
            pending.removeFirst()
            confidence = .confirmed
        }
        if pending.contains(where: { now - $0.madeAt > timeout }) { reset() }
    }

    private mutating func reset() {
        pending.removeAll()
        confidence = .unknown
    }
}
