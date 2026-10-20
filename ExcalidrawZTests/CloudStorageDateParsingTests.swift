import XCTest
@testable import ExcalidrawZ

/// Provider listings decode many dates through one cached parser.
final class CloudStorageDateParsingTests: XCTestCase {
    func testParsesWithAndWithoutFractionalSeconds() throws {
        let plain = try XCTUnwrap(CloudStorageISO8601.date(from: "2026-10-20T08:15:30Z"))
        let fractional = try XCTUnwrap(CloudStorageISO8601.date(from: "2026-10-20T08:15:30.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.25, accuracy: 0.001)
        XCTAssertNil(CloudStorageISO8601.date(from: "not a date"))
    }

    func testDropboxDecoderUsesSharedParser() throws {
        struct Stamp: Decodable { let at: Date }
        let decoded = try JSONDecoder.dropboxDecoder().decode(Stamp.self, from: Data(#"{"at":"2026-10-20T08:15:30Z"}"#.utf8))
        XCTAssertEqual(decoded.at, CloudStorageISO8601.date(from: "2026-10-20T08:15:30Z"))
    }
}
