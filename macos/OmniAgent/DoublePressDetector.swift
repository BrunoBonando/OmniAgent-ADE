import AppKit

/// Single vs double press on tree rows, where AppKit's `clickCount` is out of
/// reach behind `ShellRowView`'s own mouse handling. Pure: feed it presses, it
/// answers "was that the second press on the same target in time?".
struct DoublePressDetector {
    let interval: TimeInterval
    private var lastTarget: String?
    private var lastTime: TimeInterval = -.infinity

    /// Defaults to the user's own double-click speed, so the tree matches
    /// every other list on the machine rather than a number chosen here.
    init(interval: TimeInterval = NSEvent.doubleClickInterval) {
        self.interval = interval
    }

    mutating func register(_ target: String, at time: TimeInterval) -> Bool {
        let isDouble = target == lastTarget && time - lastTime <= interval
        // A recognised double resets, so a triple-click is double + single.
        lastTarget = isDouble ? nil : target
        lastTime = time
        return isDouble
    }
}
