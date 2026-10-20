import XCTest
import CoreData
@testable import ExcalidrawZ

/// Tool, restore and import checkpoints of linked and provider files store full
/// documents inline; they must not accumulate without bound.
@MainActor
final class LocalCheckpointRetentionTests: XCTestCase {
    func testToolCheckpointsAreCappedPerFileAndUserHistoryIsKept() async throws {
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertTrue(AppRuntime.isRunningTests && stores.allSatisfy { $0.type == NSInMemoryStoreType })
        let reference = CloudStorageDocumentReference(
            locationID: UUID(), providerID: .init(rawValue: "test"), accountID: .init(rawValue: "account"),
            itemID: .init(rawValue: UUID().uuidString), lastKnownName: "Retention"
        )
        let url = reference.checkpointURL
        try await LocalFileCheckpointStore.recordUserEdit(content: Data("user".utf8), for: url, newCheckpoint: true)
        for index in 0..<60 {
            _ = try await CloudStorageCheckpointStore.record(
                content: Data("tool-\(index)".utf8), for: reference, source: .mcpPost, description: nil
            )
        }

        let context = PersistenceController.shared.newTaskContext()
        let contents: [String] = try await context.perform {
            let request: NSFetchRequest<LocalFileCheckpoint> = LocalFileCheckpoint.fetchRequest()
            request.predicate = NSPredicate(format: "url == %@", url as NSURL)
            return try context.fetch(request).compactMap { $0.content.map { String(decoding: $0, as: UTF8.self) } }
        }
        XCTAssertEqual(contents.filter { $0.hasPrefix("tool-") }.count, 50)
        XCTAssertTrue(contents.contains("tool-59"), "the newest checkpoint is kept")
        XCTAssertFalse(contents.contains("tool-0"), "the oldest checkpoints are deleted")
        XCTAssertTrue(contents.contains("user"), "user edit history has its own limit")
    }
}
