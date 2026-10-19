import CoreData
import XCTest
@testable import ExcalidrawZ

/// Uses the hosted in-memory store; rows have no stored payload, so no files are written.
final class CheckpointRetentionTests: XCTestCase {
    func testExpiredCheckpointsAreDeletedNotOrphaned() async throws {
        XCTAssertTrue(AppRuntime.isRunningTests)
        let limit = FileRepository.maximumCheckpointsPerFile
        let context = PersistenceController.shared.newTaskContext()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let (fileID, oldestIDs) = try await context.perform { () throws -> (NSManagedObjectID, Set<UUID>) in
            let file = File(context: context)
            file.id = UUID()
            file.name = "Retention \(UUID().uuidString)"
            file.createdAt = start
            file.updatedAt = start
            var oldest = Set<UUID>()
            for index in 0..<(limit + 5) {
                let checkpoint = FileCheckpoint(context: context)
                let id = UUID()
                checkpoint.id = id
                checkpoint.updatedAt = start.addingTimeInterval(TimeInterval(index))
                file.addToCheckpoints(checkpoint)
                if index < 5 { oldest.insert(id) }
            }
            try context.save()
            return (file.objectID, oldest)
        }

        let expired = try await context.perform { () throws -> [NSManagedObjectID] in
            let file = try XCTUnwrap(context.existingObject(with: fileID) as? File)
            return FileRepository.expiredCheckpointIDs(of: file, context: context)
        }
        XCTAssertEqual(expired.count, 5)
        for id in expired {
            try await PersistenceController.shared.checkpointRepository.deleteCheckpoint(checkpointObjectID: id)
        }

        let verify = PersistenceController.shared.newTaskContext()
        try await verify.perform {
            let file = try XCTUnwrap(verify.existingObject(with: fileID) as? File)
            let linked = try PersistenceController.shared.fetchFileCheckpoints(of: file, viewContext: verify)
            XCTAssertEqual(linked.count, limit)
            XCTAssertTrue(linked.allSatisfy { !oldestIDs.contains($0.id!) }, "Only the oldest are removed")
            let request = NSFetchRequest<FileCheckpoint>(entityName: "FileCheckpoint")
            request.predicate = NSPredicate(format: "id IN %@", Array(oldestIDs))
            XCTAssertEqual(try verify.count(for: request), 0, "Expired rows must not linger as orphans")
            XCTAssertTrue(FileRepository.expiredCheckpointIDs(of: file, context: verify).isEmpty)
            verify.delete(file)
            linked.forEach(verify.delete)
            try verify.save()
        }
    }
}
