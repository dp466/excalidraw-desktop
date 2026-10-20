import XCTest
import CoreData
@testable import ExcalidrawZ

/// Deleting a drawing cleans its images with a scan limited to those images.
/// It must reach the same verdict as the full Settings scan.
final class MediaCleanupTargetedTests: XCTestCase {
    func testTargetedCleanupMatchesFullScanAndKeepsReferencedMedia() async throws {
        let context = PersistenceController.shared.newTaskContext()
        let suffix = UUID().uuidString
        let keepID = "keep-\(suffix)", historyID = "hist-\(suffix)", dropID = "drop-\(suffix)"

        func scene(_ mediaIDs: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "excalidraw", "version": 2,
                "elements": mediaIDs.map { ["type": "image", "fileId": $0, "isDeleted": false] },
                "appState": [:],
            ])
        }

        let (fileObjectID, mediaURIs) = try await context.perform {
            let owner = File(context: context)
            owner.id = UUID(); owner.name = "owner"; owner.createdAt = .now; owner.updatedAt = .now
            owner.content = try scene([keepID])
            let checkpoint = FileCheckpoint(context: context)
            checkpoint.id = UUID(); checkpoint.updatedAt = .now
            checkpoint.content = try scene([historyID])
            owner.addToCheckpoints(checkpoint)
            var items: [MediaItem] = []
            for mediaID in [keepID, historyID, dropID] {
                let item = MediaItem(context: context)
                item.id = mediaID
                item.mimeType = "image/png"
                item.dataURL = "data:image/png;base64,AAAA"
                item.file = owner
                items.append(item)
            }
            try context.save()
            return (owner.objectID, items.map { $0.objectID.uriRepresentation() })
        }
        defer {
            let cleanup = PersistenceController.shared.newTaskContext()
            cleanup.performAndWait {
                if let file = try? cleanup.existingObject(with: fileObjectID) {
                    cleanup.delete(file)
                    try? cleanup.save()
                }
            }
        }

        let targets = Set(mediaURIs)
        let expected = Set(
            try await MediaCleanupCoordinator.shared.scan().orphaned
                .map { $0.id.uriRepresentation() }
                .filter(targets.contains)
        )
        let deletedCount = try await MediaCleanupCoordinator.shared.cleanOrphanedMedia(withObjectURIs: mediaURIs)
        XCTAssertEqual(deletedCount, expected.count)

        let remainingIDs = try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "MediaItem")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            request.predicate = NSPredicate(format: "id IN %@", [keepID, historyID, dropID])
            return Set(try context.fetch(request).compactMap { $0["id"] as? String })
        }
        XCTAssertTrue(remainingIDs.contains(keepID), "media used by a current drawing is kept")
        XCTAssertTrue(remainingIDs.contains(historyID), "media used only by history is kept")
        XCTAssertEqual(remainingIDs.contains(dropID), expected.isEmpty, "unused media goes unless other content was unreadable")
    }
}
