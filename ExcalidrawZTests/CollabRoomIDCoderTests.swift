import XCTest
@testable import ExcalidrawZ

/// Room links arrive from pasted or opened URLs, so malformed codes must be rejected.
final class CollabRoomIDCoderTests: XCTestCase {
    func testRoundTrip() {
        let encoded = CollabRoomIDCoder.shared.encode(roomID: "room-123,key")
        XCTAssertEqual(CollabRoomIDCoder.shared.decode(encodedString: encoded), "room-123,key")
    }

    func testOddLengthAndNonHexCodesAreRejected() {
        XCTAssertNil(CollabRoomIDCoder.shared.decode(encodedString: "abc"))
        XCTAssertNil(CollabRoomIDCoder.shared.decode(encodedString: "a"))
        XCTAssertNil(CollabRoomIDCoder.shared.decode(encodedString: "zz"))
    }
}
