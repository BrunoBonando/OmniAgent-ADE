import os

enum Instrumentation {
    static let log = OSLog(
        subsystem: "digital.bruno.omniagent",
        category: .pointsOfInterest
    )
}
