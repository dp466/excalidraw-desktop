#if os(macOS)
import XCTest
@testable import ExcalidrawZ

/// Quitting waits for the backup only for a bounded time: a Keychain access
/// prompt can otherwise hold the app open indefinitely.
@MainActor
final class TerminationTimeLimitTests: XCTestCase {
    func testStuckOperationReleasesQuitAfterTheLimit() async {
        let start = Date()
        let finished = await AppDelegate.waitAtMost(seconds: 0.3) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        XCTAssertFalse(finished)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testFinishedOperationReturnsAtOnce() async {
        let start = Date()
        var ran = false
        let finished = await AppDelegate.waitAtMost(seconds: 30) { ran = true }
        XCTAssertTrue(finished)
        XCTAssertTrue(ran)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
#endif
