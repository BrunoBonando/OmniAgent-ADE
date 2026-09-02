import XCTest
@testable import OmniAgent

final class FrameCodecTests: XCTestCase {
    func testDelayedPartialReadsProduceOneFrameOnlyWhenComplete() throws {
        let expected = SessionFrame(
            kind: .output,
            requestOrSequence: 0x0102_0304_0506_0708,
            payload: Data([0, 0xff, 0x1b, 0x5b])
        )
        let encoded = try expected.encoded()
        var decoder = FrameDecoder()
        var decoded: [SessionFrame] = []

        for byte in encoded {
            decoded += try decoder.append(Data([byte]))
        }

        XCTAssertEqual(decoded, [expected])
    }

    func testMalformedHeadersAreRejectedBeforePayloadAllocation() throws {
        // Written against the constant rather than a literal: the wire version
        // moves (1 -> 2 with environment sharing), and a test that hard-codes
        // "2 is unsupported" quietly asserts the opposite of the truth the day
        // 2 ships.
        let unsupported = SessionFrame.protocolVersion &+ 1
        var unsupportedVersion = Data(repeating: 0, count: 16)
        unsupportedVersion[4] = unsupported
        unsupportedVersion[5] = MessageKind.hello.rawValue
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(unsupportedVersion)) {
            XCTAssertEqual($0 as? SessionProtocolError, .unsupportedVersion(unsupported))
        }

        var oversized = Data(repeating: 0, count: 16)
        oversized.replaceSubrange(0..<4, with: UInt32(1_048_577).bigEndianBytes)
        oversized[4] = SessionFrame.protocolVersion
        oversized[5] = MessageKind.output.rawValue
        decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(oversized)) {
            XCTAssertEqual($0 as? SessionProtocolError, .payloadTooLarge(1_048_577))
        }
    }

    func testRawPayloadRoundTripsArbitraryBytes() throws {
        let bytes = Data([0, 0xff, 0x1b, 0x5b, 0x32, 0x4a])
        let payload = try RawPayload.encode(sessionID: "native-terminal", bytes: bytes)
        let decoded = try RawPayload.decode(payload)

        XCTAssertEqual(decoded.sessionID, "native-terminal")
        XCTAssertEqual(decoded.bytes, bytes)
    }

    func testDecoderHandlesAFrameAfterRemovingThePreviousFrame() throws {
        var decoder = FrameDecoder()
        let first = SessionFrame(kind: .helloAck, requestOrSequence: 1, payload: Data([1]))
        let second = SessionFrame(kind: .output, requestOrSequence: 2, payload: Data([2]))

        XCTAssertEqual(try decoder.append(first.encoded()), [first])
        XCTAssertEqual(try decoder.append(second.encoded()), [second])
    }
}
