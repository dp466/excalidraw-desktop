import XCTest
import CoreData
@testable import ExcalidrawZ

/// DiffScan lists the storage files Core Data expects, reading only the
/// identifying attributes.
final class ExpectedFilesEnumerationTests: XCTestCase {
    func testListsFilesCheckpointsAndMediaByIdentity() async throws {
        let context = PersistenceController.shared.newTaskContext()
        let fileID = UUID(), checkpointID = UUID(), mediaID = "media-\(UUID().uuidString)"
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        try await context.perform {
            let file = File(id: fileID, name: "listed", context: context)
            file.updatedAt = created
            let checkpoint = FileCheckpoint(context: context)
            checkpoint.id = checkpointID
            checkpoint.updatedAt = created
            checkpoint.file = file
            let media = MediaItem(context: context)
            media.id = mediaID
            media.mimeType = "image/png"
            media.createdAt = created
            media.dataURL = "data:image/png;base64,AAAA"
            media.file = file
            try context.save()
        }
        defer {
            context.performAndWait {
                for request in [File.fetchRequest(), FileCheckpoint.fetchRequest(), MediaItem.fetchRequest()] as [NSFetchRequest<NSFetchRequestResult>] {
                    for case let object as NSManagedObject in (try? context.fetch(request)) ?? [] {
                        context.delete(object)
                    }
                }
                try? context.save()
            }
        }

        let enumerator = FileEnumerator(localManager: LocalStorageManager(), iCloudManager: iCloudDriveFileManager())
        let expected = await enumerator.enumerateExpectedFiles()
        let byID = Dictionary(expected.map { ($0.fileID, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(byID[fileID.uuidString]?.relativePath, "Files/\(fileID.uuidString).excalidrawz")
        XCTAssertEqual(byID[fileID.uuidString]?.modifiedAt, created)
        XCTAssertEqual(byID[checkpointID.uuidString]?.relativePath, "Checkpoints/\(checkpointID.uuidString).excalidrawz_checkpoint")
        XCTAssertEqual(byID[mediaID]?.relativePath, "MediaItems/\(mediaID).png")
    }
}
