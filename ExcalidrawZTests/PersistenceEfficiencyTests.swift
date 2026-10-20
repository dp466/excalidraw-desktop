import CoreData
import XCTest
@testable import ExcalidrawZ

/// Hosted in-memory store only; no payloads are written to storage.
final class PersistenceEfficiencyTests: XCTestCase {
    func testExistingMediaIDsAndSyncPlanReadOnlyIDs() async throws {
        XCTAssertTrue(AppRuntime.isRunningTests)
        let context = PersistenceController.shared.newTaskContext()
        let prefix = UUID().uuidString
        let fileID = try await context.perform { () throws -> NSManagedObjectID in
            let file = File(context: context)
            file.id = UUID(); file.name = "media \(prefix)"; file.createdAt = .now; file.updatedAt = .now
            for index in 0..<3 {
                let item = MediaItem(context: context)
                item.id = "\(prefix)-\(index)"
                item.mimeType = "image/png"
                item.filePath = "stored/\(index).png" // already in storage: nothing to repair
                item.file = file
            }
            try context.save()
            return file.objectID
        }

        let found = try await MediaItem.existingIDs(among: ["\(prefix)-0", "\(prefix)-2", "\(prefix)-missing"], context: context)
        XCTAssertEqual(found, ["\(prefix)-0", "\(prefix)-2"])
        let none = try await MediaItem.existingIDs(among: [], context: context)
        XCTAssertTrue(none.isEmpty)

        var scene = ExcalidrawFile()
        for index in 0..<3 {
            let id = "\(prefix)-\(index)"
            scene.files[id] = .init(mimeType: "image/png", id: id, createdAt: nil, dataURL: "data:image/png;base64,AA==", lastRetrievedAt: nil)
        }
        let changed = try await PersistenceController.shared.mediaItemRepository.syncMediaItemsForFile(
            excalidrawFile: scene, fileObjectID: fileID
        )
        XCTAssertTrue(changed.isEmpty, "existing stored items need neither creation nor repair")

        try await context.perform {
            let file = try XCTUnwrap(context.existingObject(with: fileID) as? File)
            (file.medias?.allObjects as? [MediaItem] ?? []).forEach(context.delete)
            context.delete(file)
            try context.save()
        }
    }

    func testCheckpointUpdateReplacesNewestOnly() async throws {
        let url = URL(fileURLWithPath: "/private/tmp/checkpoint-\(UUID().uuidString).excalidraw")
        try await LocalFileCheckpointStore.recordUserEdit(content: Data("a".utf8), for: url, newCheckpoint: true)
        try await LocalFileCheckpointStore.recordUserEdit(content: Data("b".utf8), for: url, newCheckpoint: true)
        try await LocalFileCheckpointStore.recordUserEdit(content: Data("c".utf8), for: url, newCheckpoint: false)
        let context = PersistenceController.shared.newTaskContext()
        try await context.perform {
            let request = NSFetchRequest<LocalFileCheckpoint>(entityName: "LocalFileCheckpoint")
            request.predicate = NSPredicate(format: "url == %@", url as NSURL)
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            let rows = try context.fetch(request)
            XCTAssertEqual(rows.map { String(decoding: $0.content ?? Data(), as: UTF8.self) }, ["c", "a"])
            rows.forEach(context.delete)
            try context.save()
        }
    }
}
