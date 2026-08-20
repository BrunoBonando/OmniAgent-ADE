import XCTest
@testable import OmniAgent

/// `DeskCanvasCodec`: the native-only `desk_canvas_native` row's
/// serialize/deserialize pair. Repair shape is `BrowserPanesCodec`'s (a bad
/// field costs the field, a bad entry costs the entry) and the version gate
/// is `UsageAnalyticsCodec`'s (a future build's row is discarded whole, not
/// half-repaired — cheap here, because losing the row costs only pins and a
/// camera, both of which the canvas recomputes).
final class DeskCanvasStateTests: XCTestCase {
    func testRoundTrip() {
        let state = DeskCanvasState(
            pinned: ["session-g1": CGPoint(x: 120, y: -40), "root": CGPoint(x: 0, y: 0)],
            camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 12, y: -34))
        )

        XCTAssertEqual(DeskCanvasCodec.deserialize(DeskCanvasCodec.serialize(state)), state)
    }

    func testRoundTripWithNoCameraAndNoPins() {
        let state = DeskCanvasState()

        XCTAssertEqual(DeskCanvasCodec.deserialize(DeskCanvasCodec.serialize(state)), state)
    }

    func testMissingOrGarbageRawDeserializesToTheDefaultState() {
        XCTAssertEqual(DeskCanvasCodec.deserialize(nil), DeskCanvasState())
        XCTAssertEqual(DeskCanvasCodec.deserialize(""), DeskCanvasState())
        XCTAssertEqual(DeskCanvasCodec.deserialize("}{ not json"), DeskCanvasState())
        XCTAssertEqual(DeskCanvasCodec.deserialize(#"{"pinned":7,"version":1}"#), DeskCanvasState())
    }

    func testAFutureVersionRowIsDiscardedWholeRatherThanHalfRepaired() {
        let raw = #"{"camera":{"scale":0.5,"x":0,"y":0},"pinned":{"a":{"x":1,"y":2}},"version":2}"#

        XCTAssertEqual(
            DeskCanvasCodec.deserialize(raw),
            DeskCanvasState(),
            "a row a future build wrote is thrown away, not partially read"
        )
    }

    func testAMalformedPinCostsOnlyThatNodeNotTheWholeRow() {
        let raw = #"""
        {"pinned":{
          "good":{"x":1,"y":2},
          "wrong-type":{"x":"nope","y":2},
          "not-a-point":7
        },"version":1}
        """#

        let state = DeskCanvasCodec.deserialize(raw)

        XCTAssertEqual(state.pinned, ["good": CGPoint(x: 1, y: 2)])
    }

    func testAMalformedCameraCostsOnlyTheCameraNotThePins() {
        let raw = #"{"camera":{"scale":0,"x":0,"y":0},"pinned":{"good":{"x":1,"y":2}},"version":1}"#

        let state = DeskCanvasCodec.deserialize(raw)

        XCTAssertNil(state.camera, "a zero scale is a singular transform, not a camera")
        XCTAssertEqual(state.pinned, ["good": CGPoint(x: 1, y: 2)], "the pins survive it")
    }

    func testAnOverscaledCameraIsClampedToMaxScaleRatherThanDropped() {
        let raw = #"{"camera":{"scale":4,"x":0,"y":0},"pinned":{},"version":1}"#

        XCTAssertEqual(
            DeskCanvasCodec.deserialize(raw).camera,
            DeskCamera(scale: DeskCamera.maxScale, origin: .zero)
        )
    }

    func testANonFinitePinIsDroppedRatherThanPoisoningTheTransform() {
        let json = DeskCanvasCodec.serialize(
            DeskCanvasState(pinned: ["bad": CGPoint(x: CGFloat.nan, y: 0)], camera: nil)
        )

        XCTAssertEqual(
            json,
            #"{"pinned":{},"version":1}"#,
            "a NaN in a CATransform3D is a silently invisible view, not a crash"
        )
    }

    func testAControlCharacterOrOverlongNodeIDDropsOnlyThatPin() {
        let json = DeskCanvasCodec.serialize(
            DeskCanvasState(
                pinned: [
                    "workspace:OmniAgent-ADE": CGPoint(x: 3, y: 4),
                    "bad\u{7}id": CGPoint(x: 1, y: 2),
                    String(repeating: "a", count: DeskCanvasCodec.maxNodeIDLength + 1): CGPoint(x: 5, y: 6),
                ],
                camera: nil
            )
        )

        XCTAssertEqual(json, #"{"pinned":{"workspace:OmniAgent-ADE":{"x":3,"y":4}},"version":1}"#)
    }

    func testSerializeOutputIsStableAndSorted() {
        // Key order is what this pins: top level `camera` < `pinned` <
        // `version`, and `pinned`'s own node-id keys sorted. `pinned` is a
        // dictionary keyed by node id, so without `.sortedKeys` its order is
        // unstable by construction and `write(_:to:)`'s dedupe never fires.
        let json = DeskCanvasCodec.serialize(
            DeskCanvasState(
                pinned: ["session-g1": CGPoint(x: 120, y: -40), "root": CGPoint(x: 0, y: 0)],
                camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 12, y: -34))
            )
        )

        XCTAssertEqual(
            json,
            #"{"camera":{"scale":0.5,"x":12,"y":-34},"pinned":{"root":{"x":0,"y":0},"session-g1":{"x":120,"y":-40}},"version":1}"#
        )
    }

    func testSerializingIsByteStableSoTheUnchangedRowGuardHolds() {
        // The gotcha this test exists for: `write(_:to:)` suppresses a write
        // only when the serialized string is byte-identical, and this row
        // stores floats. A camera whose scale is 0.5000000000000001 one frame
        // and 0.5 the next would otherwise serialize differently and defeat
        // the only throttle in the system.
        let jittered = DeskCanvasState(
            pinned: ["a": CGPoint(x: 120.0000001, y: -40.4)],
            camera: DeskCamera(scale: 0.5000000000000001, origin: CGPoint(x: 12.2, y: -33.7))
        )
        let settled = DeskCanvasState(
            pinned: ["a": CGPoint(x: 120, y: -40)],
            camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 12, y: -34))
        )

        XCTAssertEqual(DeskCanvasCodec.serialize(jittered), DeskCanvasCodec.serialize(settled))
        XCTAssertEqual(DeskCanvasCodec.serialize(jittered), DeskCanvasCodec.serialize(jittered))
    }

    func testNegativeZeroSerializesAsZero() {
        // Two visually identical origins that print differently (`-0` vs `0`)
        // would each look like a change to the dedupe.
        XCTAssertEqual(
            DeskCanvasCodec.serialize(
                DeskCanvasState(pinned: ["a": CGPoint(x: -0.4, y: 0)], camera: nil)
            ),
            #"{"pinned":{"a":{"x":0,"y":0}},"version":1}"#
        )
    }

    func testSettingsKey() {
        XCTAssertEqual(SettingsKey.deskCanvas, "desk_canvas_native")
    }
}
