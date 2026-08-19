import Foundation

/// The Desk canvas's persisted state: the pinned node positions the tidy
/// tree must honour, and the camera the canvas comes back to. Unpinned nodes
/// are recomputed by `DeskCanvas.layout` on every launch and are deliberately
/// not stored — which is also why losing this row is cheap.
///
/// `pinned` is keyed by `DeskNode.id` and holds positions in the canvas's own
/// **flipped** space (`PaneWorkspaceView.isFlipped == true`, y growing
/// downward), the same space `DeskCanvasLayout.frames` uses.
struct DeskCanvasState: Equatable {
    var pinned: [String: CGPoint] = [:]
    var camera: DeskCamera?
}

/// Serializes/deserializes the `desk_canvas_native` settings row —
/// `{"version":1,"pinned":{<node id>:{x,y}},"camera":{scale,x,y}}`.
///
/// `JSONSerialization` rather than `Codable`, the house convention stated at
/// `PersistedLayoutCodec`: a throwing decode of one malformed element fails
/// the whole parse, and the repair contract here is `BrowserPanesCodec`'s —
/// a bad field costs the field, a bad entry costs the entry.
///
/// Versioned like `UsageAnalyticsCodec`: a row a *future* build wrote is
/// discarded whole rather than half-repaired.
enum DeskCanvasCodec {
    static let version = 1

    /// A `DeskNode.id` length bound. Deliberately looser than
    /// `SessionIdentifier.isValid`, which is byte-strict because, per its own
    /// doc, "an id becomes both a transcript filename and a tmux target on
    /// the Rust side". A node id is neither: it namespaces a brain project id
    /// (an arbitrary label that may hold spaces and non-ASCII) or a group id.
    /// So only the two things that make a key unusable are rejected —
    /// unbounded length and control characters.
    static let maxNodeIDLength = 256

    static func serialize(_ state: DeskCanvasState) -> String {
        var pinned: [String: Any] = [:]
        for (id, point) in state.pinned where isValidNodeID(id) {
            guard let x = coordinate(point.x), let y = coordinate(point.y) else { continue }
            pinned[id] = ["x": x, "y": y]
        }
        // Absence is the missing key, never `null` — `WorkspaceRestoration`'s
        // rule for the shared row, applied here.
        var payload: [String: Any] = ["version": version, "pinned": pinned]
        if let camera = state.camera,
           let scale = quantizedScale(camera.scale),
           let x = coordinate(camera.origin.x),
           let y = coordinate(camera.origin.y) {
            payload["camera"] = ["scale": scale, "x": x, "y": y]
        }
        guard
            JSONSerialization.isValidJSONObject(payload),
            // `.sortedKeys` for exactly `PersistedLayoutCodec.serialize`'s
            // reason: `WorkspaceWindowController.write(_:to:)` dedupes a
            // settings write by comparing this string to the last one
            // written, and `Dictionary` iteration order is not stable across
            // two dictionaries holding the same pairs. It matters more here
            // than in either pane row: `pinned` *is* a dictionary keyed by
            // node id, so its order is unstable by construction.
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"pinned":{},"version":1}"#
        }
        return json
    }

    /// Never throws — a corrupt, missing or future-version row restores to
    /// "no pins, no camera" rather than breaking launch. Repair rules:
    ///
    /// - a `version` that is not exactly `1` discards the whole row (a future
    ///   build's shape must not be half-read);
    /// - a pin whose value is not `{x, y}` of finite in-range numbers drops
    ///   just that node;
    /// - a node id that is empty, over `maxNodeIDLength`, or holds a control
    ///   character drops just that node;
    /// - a camera with a non-finite or non-positive scale, or an unreadable
    ///   origin, drops just the camera — the pins survive it;
    /// - a scale above `DeskCamera.maxScale` is clamped, not dropped (the
    ///   spec's "no zoom above 1.0" is a clamp everywhere else too).
    static func deserialize(_ raw: String?) -> DeskCanvasState {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            number(parsed["version"]) == Double(version)
        else {
            return DeskCanvasState()
        }

        var state = DeskCanvasState()
        if let rawPinned = parsed["pinned"] as? [String: Any] {
            for (id, value) in rawPinned {
                guard isValidNodeID(id), let point = decodePoint(value) else { continue }
                state.pinned[id] = point
            }
        }
        if let rawCamera = parsed["camera"] as? [String: Any],
           let rawScale = number(rawCamera["scale"]),
           let scale = quantizedScale(CGFloat(rawScale)),
           let origin = decodePoint(rawCamera) {
            state.camera = DeskCamera(scale: CGFloat(scale), origin: origin)
        }
        return state
    }

    private static func decodePoint(_ value: Any?) -> CGPoint? {
        guard
            let dict = value as? [String: Any],
            let x = number(dict["x"]).flatMap({ coordinate(CGFloat($0)) }),
            let y = number(dict["y"]).flatMap({ coordinate(CGFloat($0)) })
        else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// `UsageAnalytics.swift:423`'s decoder verbatim. `as? Double` reads an
    /// integral JSON number too, through `NSNumber` bridging; `as? Int` on a
    /// fractional value returns nil, so `Double` is the only safe choice for
    /// anything geometric.
    private static func number(_ raw: Any?) -> Double? {
        raw as? Double
    }

    /// Positions round to whole canvas points. Two reasons, both real:
    /// `write(_:to:)`'s dedupe is *string* equality and there is no debounce
    /// helper anywhere in `WorkspaceWindowController`, so an origin of
    /// 12.2000001 and one of 12.2 would look like two different rows; and a
    /// pin is where a drag landed, where sub-point precision is noise.
    /// `+ 0` collapses `-0.0` onto `0.0`, which otherwise prints as `-0` and
    /// makes an unchanged position look changed. The `isFinite` guard is
    /// `UsageAnalyticsCodec.nonNegative`'s, and it is what keeps a NaN out of
    /// a `CATransform3D` — a silently invisible view, not a crash.
    private static func coordinate(_ value: CGFloat) -> Double? {
        guard value.isFinite, abs(value) <= 1_000_000 else { return nil }
        return Double(value).rounded() + 0
    }

    /// Scale quantizes to four places — finer than any zoom step the camera
    /// takes, and still enough to collapse 0.5000000000000001 onto 0.5.
    /// Clamped at `DeskCamera.maxScale`; a non-positive scale is a singular
    /// transform, not a camera, so it drops the camera instead.
    private static func quantizedScale(_ value: CGFloat) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        let capped = min(Double(value), Double(DeskCamera.maxScale))
        return (capped * 10_000).rounded() / 10_000 + 0
    }

    private static func isValidNodeID(_ value: String) -> Bool {
        guard (1...maxNodeIDLength).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}
