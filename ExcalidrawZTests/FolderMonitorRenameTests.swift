#if os(macOS)
import XCTest
@testable import ExcalidrawZ

/// Finder renames, moves and Move to Trash reach FSEvents as renames of the
/// old path. The old path must be reported as deleted so an open drawing is
/// not recreated there by its next save.
final class FolderMonitorRenameTests: XCTestCase {
    private actor Events {
        var items: [FileEvent] = []
        func append(_ event: FileEvent) { items.append(event) }
    }

    func testMovingAFileOutOfTheFolderReportsTheOldPathDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-" + UUID().uuidString, isDirectory: true)
        let watched = root.appendingPathComponent("watched", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = watched.appendingPathComponent("open.excalidraw")
        try Data("{}".utf8).write(to: file)

        let events = Events()
        let monitor = try MacOSFileSystemMonitor(folderURL: watched, options: .default) { await events.append($0) }
        try await monitor.start()
        defer { Task { await monitor.stop() } }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try FileManager.default.moveItem(at: file, to: outside.appendingPathComponent("open.excalidraw"))

        let deadline = Date().addingTimeInterval(10)
        var sawDeletion = false
        while Date() < deadline, !sawDeletion {
            try await Task.sleep(nanoseconds: 100_000_000)
            sawDeletion = await events.items.contains {
                if case .deleted(let url) = $0 { return url.path.hasSuffix("/watched/open.excalidraw") }
                return false
            }
        }
        let summary = await events.items.map { String(describing: $0) }
        XCTAssertTrue(sawDeletion, "events: \(summary)")
    }
}
#endif
