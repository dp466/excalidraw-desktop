//
//  LocalFileCheckpointStore.swift
//  ExcalidrawZ
//

import CoreData
import Foundation

/// Device-managed user history for Linked Folder and provider-backed files.
enum LocalFileCheckpointStore {
    private static let maximumUserCheckpointCount = 50
    /// MCP, AI, restore and provider checkpoints, counted separately so tool
    /// activity cannot push out user history.
    private static let maximumToolCheckpointCount = 50

    /// Inserts a non-user checkpoint and deletes that file's oldest ones beyond
    /// `maximumToolCheckpointCount`. Call inside `context.perform`; the caller saves.
    static func insertToolCheckpoint(
        content: Data,
        for fileURL: URL,
        source: FileCheckpointSource,
        description: String?,
        in context: NSManagedObjectContext
    ) throws -> UUID {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "LocalFileCheckpoint")
        request.resultType = .managedObjectIDResultType
        request.predicate = NSPredicate(
            format: "url == %@ AND source != nil AND source != %@",
            fileURL as NSURL,
            FileCheckpointSource.user.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchOffset = maximumToolCheckpointCount - 1
        for objectID in try context.fetch(request) {
            context.delete(context.object(with: objectID))
        }

        let checkpoint = LocalFileCheckpoint(context: context)
        let checkpointID = UUID()
        checkpoint.id = checkpointID
        checkpoint.url = fileURL
        checkpoint.content = content
        checkpoint.updatedAt = .now
        checkpoint.source = source.rawValue
        checkpoint.historyDescription = description
        return checkpointID
    }

    static func recordUserEdit(
        content: Data,
        for fileURL: URL,
        newCheckpoint: Bool
    ) async throws {
        let context = PersistenceController.shared.container.newBackgroundContext()
        try await context.perform {
            let request: NSFetchRequest<LocalFileCheckpoint> = LocalFileCheckpoint.fetchRequest()
            request.predicate = NSPredicate(
                format: "url == %@ AND (source == nil OR source == %@)",
                fileURL as NSURL,
                FileCheckpointSource.user.rawValue
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "updatedAt", ascending: false)
            ]

            // Most autosaves only replace the newest checkpoint; do not load
            // every retained row (and inline content) to find it.
            if !newCheckpoint {
                request.fetchLimit = 1
                if let latest = try context.fetch(request).first {
                    latest.content = content
                    latest.updatedAt = .now
                    if latest.source == nil {
                        latest.source = FileCheckpointSource.user.rawValue
                    }
                    try context.save()
                    return
                }
                request.fetchLimit = 0
            }

            let checkpoints = try context.fetch(request)
            let checkpoint = LocalFileCheckpoint(context: context)
            checkpoint.id = UUID()
            checkpoint.url = fileURL
            checkpoint.updatedAt = .now
            checkpoint.content = content
            checkpoint.source = FileCheckpointSource.user.rawValue

            let excessCount = max(
                0,
                checkpoints.count + 1 - maximumUserCheckpointCount
            )
            for checkpoint in checkpoints.suffix(excessCount) {
                context.delete(checkpoint)
            }
            try context.save()
        }
    }
}
