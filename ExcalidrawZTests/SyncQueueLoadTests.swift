import XCTest
@testable import ExcalidrawZ

/// An event queued right after launch must join, not replace, the queue
/// persisted by the previous run.
final class SyncQueueLoadTests: XCTestCase {
    private let key = "com.excalidrawz.syncQueue"

    func testEarlyEnqueueKeepsPersistedEvents() async throws {
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let persisted = SyncEvent(fileID: "persisted", relativePath: "Files/persisted.excalidrawz", operation: .uploadToCloud)
        UserDefaults.standard.set(try JSONEncoder().encode([persisted]), forKey: key)

        let queue = SyncQueue()
        await queue.enqueue(SyncEvent(fileID: "early", relativePath: "Files/early.excalidrawz", operation: .uploadToCloud, priority: .high))

        let ids = await queue.getAll().map(\.fileID)
        XCTAssertEqual(Set(ids), ["persisted", "early"])
        XCTAssertEqual(ids.first, "early", "high priority goes ahead of the persisted background work")
    }
}
