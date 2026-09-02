import XCTest
@testable import OmniAgent

/// The account circle, on its own — the sidebar row and the title bar both
/// wear one, and this is the fact both of them depend on.
final class AccountAvatarViewTests: XCTestCase {
    func testNoNameIsTheGenericGlyph() {
        let avatar = AccountAvatarView(diameter: 22)
        XCTAssertEqual(avatar.mode, .glyph)
        avatar.apply(name: nil, picture: nil)
        XCTAssertEqual(avatar.mode, .glyph)
        avatar.apply(name: "   ", picture: nil)
        XCTAssertEqual(avatar.mode, .glyph, "a blank name is no name")
    }

    func testANameWithoutAPictureBecomesItsInitials() {
        let avatar = AccountAvatarView(diameter: 22)
        avatar.apply(name: "Bruno Bonando", picture: nil)
        XCTAssertEqual(avatar.mode, .initials("BB"))
    }

    func testAPictureTakesTheCircleOverTheInitials() {
        let avatar = AccountAvatarView(diameter: 22)
        avatar.apply(name: "Bruno Bonando", picture: NSImage(size: NSSize(width: 44, height: 44)))
        XCTAssertEqual(avatar.mode, .picture)
    }

    /// And back again: the circle must never keep the last account it was
    /// shown, or a log-out leaves someone else's face in the title bar.
    func testLosingTheNameReturnsTheCircleToTheGlyph() {
        let avatar = AccountAvatarView(diameter: 22)
        avatar.apply(name: "Bruno Bonando", picture: NSImage(size: NSSize(width: 44, height: 44)))
        avatar.apply(name: nil, picture: nil)
        XCTAssertEqual(avatar.mode, .glyph)
    }
}
