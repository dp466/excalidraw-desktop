import Foundation
import XCTest
@testable import ExcalidrawZ

final class LocalFileIDMappingTests: XCTestCase {
    func testConcurrentLookupsAgreeOnOneIDAndMovesKeepIt() {
        let url = URL(fileURLWithPath: "/private/tmp/id-mapping-\(UUID().uuidString)/a.excalidraw")
        let moved = url.deletingLastPathComponent().appendingPathComponent("b.excalidraw")
        let lock = NSLock()
        var ids = Set<String>()
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            let id = ExcalidrawFile.localFileID(for: url)
            lock.lock(); ids.insert(id); lock.unlock()
            if index % 7 == 0 { _ = ExcalidrawFile.localFileID(for: url.appendingPathExtension("\(index)")) }
        }
        XCTAssertEqual(ids.count, 1, "every caller must see the same ID for one file")
        let id = ids.first!
        ExcalidrawFile.moveLocalFileID(from: url, to: moved)
        XCTAssertNil(ExcalidrawFile.localFileURLIDMapping[url])
        XCTAssertEqual(ExcalidrawFile.localFileID(for: moved), id)
        XCTAssertNotEqual(ExcalidrawFile.localFileID(for: moved, refresh: true), id)
    }
}
