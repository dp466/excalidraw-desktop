import AppKit
import XCTest
@testable import ExcalidrawZ

final class PreviewCachePressureTests: XCTestCase {
    func testMemoryPressureReleasesRetainedPreviews() {
        let cache = FileItemPreviewCache.shared
        cache.removeAllObjects()
        let size = NSSize(width: 512, height: 384)
        for index in 0..<120 {
            let image = NSImage(size: size)
            image.lockFocus(); NSColor.systemPurple.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
            cache.setObject(image, forKey: "pressure-test-\(index)" as NSString)
        }
        let before = cache.retainedPreviewStatistics()
        cache.releaseRetainedPreviews(keepingMostRecent: 32)
        let warning = cache.retainedPreviewStatistics()
        cache.releaseRetainedPreviews(keepingMostRecent: 0)
        let critical = cache.retainedPreviewStatistics()
        print(String(format: "BENCH preview retention: before %d previews / %.1f MB, after warning %d / %.1f MB, after critical %d / %.1f MB",
                     before.count, Double(before.bytes) / 1_048_576, warning.count, Double(warning.bytes) / 1_048_576,
                     critical.count, Double(critical.bytes) / 1_048_576))
        XCTAssertEqual(warning.count, 32)
        XCTAssertEqual(critical.count, 0)
        cache.removeAllObjects()
    }
}
