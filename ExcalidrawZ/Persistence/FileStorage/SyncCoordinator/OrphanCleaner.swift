//
//  OrphanCleaner.swift
//  ExcalidrawZ
//
//  Created by Claude on 2025/12/31.
//

import Foundation
import CoreData
import Logging

/// Clean up orphaned files (files without corresponding CoreData entities)
struct OrphanCleaner {
    private let logger = Logger(label: "OrphanCleaner")
    private let localManager: LocalStorageManager
    private let iCloudManager: iCloudDriveFileManager

    init(localManager: LocalStorageManager, iCloudManager: iCloudDriveFileManager) {
        self.localManager = localManager
        self.iCloudManager = iCloudManager
    }

    // MARK: - Cleanup Operations

    /// Remove files that don't have corresponding CoreData entities
    func cleanupOrphanedFiles(
        localFiles: [SyncFileState],
        iCloudFiles: [SyncFileState]
    ) async {
        // Deleting is irreversible (and reaches iCloud): without a complete
        // ID list, an unreadable category would look entirely orphaned.
        guard let validFileIDs = await getValidFileIDs() else {
            logger.warning("Skipping orphan cleanup: could not read the stored file IDs")
            return
        }
        var deletedCount = 0

        // Clean up local orphaned files
        for file in localFiles {
            let validIDs = getValidIDs(for: file.contentType, from: validFileIDs)
            if !validIDs.contains(file.fileID) {
                try? await localManager.deleteContent(relativePath: file.relativePath)
                deletedCount += 1
            }
        }

        // Clean up iCloud orphaned files
        for file in iCloudFiles {
            let validIDs = getValidIDs(for: file.contentType, from: validFileIDs)
            if !validIDs.contains(file.fileID) {
                try? await iCloudManager.deleteContent(relativePath: file.relativePath)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            logger.info("Cleaned up \(deletedCount) orphaned file(s)")
        }
    }

    // MARK: - Helper Methods

    /// Get all valid file IDs from CoreData entities
    private func getValidFileIDs() async -> [FileStorageContentType: Set<String>]? {
        let context = PersistenceController.shared.newTaskContext()

        // All CoreData operations must run on the context's queue
        return await context.perform {
            var result: [FileStorageContentType: Set<String>] = [:]
            var didFail = false

            // Fetch File IDs
            do {
                let fileRequest: NSFetchRequest<NSFetchRequestResult> = File.fetchRequest()
                fileRequest.propertiesToFetch = ["id"]
                fileRequest.resultType = .dictionaryResultType
                let fileResults = try context.fetch(fileRequest) as? [[String: Any]] ?? []
                let fileIDs = fileResults.compactMap { ($0["id"] as? UUID)?.uuidString }
                result[.file] = Set(fileIDs)
            } catch {
                didFail = true
            }

            // Fetch CollaborationFile IDs
            do {
                let collabRequest: NSFetchRequest<NSFetchRequestResult> = CollaborationFile.fetchRequest()
                collabRequest.propertiesToFetch = ["id"]
                collabRequest.resultType = .dictionaryResultType
                let collabResults = try context.fetch(collabRequest) as? [[String: Any]] ?? []
                let collabIDs = collabResults.compactMap { ($0["id"] as? UUID)?.uuidString }
                result[.collaborationFile] = Set(collabIDs)
            } catch {
                didFail = true
            }

            // Fetch FileCheckpoint IDs
            do {
                let checkpointRequest: NSFetchRequest<NSFetchRequestResult> = FileCheckpoint.fetchRequest()
                checkpointRequest.propertiesToFetch = ["id"]
                checkpointRequest.resultType = .dictionaryResultType
                let checkpointResults = try context.fetch(checkpointRequest) as? [[String: Any]] ?? []
                let checkpointIDs = checkpointResults.compactMap { ($0["id"] as? UUID)?.uuidString }
                result[.checkpoint] = Set(checkpointIDs)
            } catch {
                didFail = true
            }

            // Fetch MediaItem IDs
            do {
                let mediaRequest: NSFetchRequest<NSFetchRequestResult> = MediaItem.fetchRequest()
                mediaRequest.propertiesToFetch = ["id"]
                mediaRequest.resultType = .dictionaryResultType
                let mediaResults = try context.fetch(mediaRequest) as? [[String: Any]] ?? []
                let mediaIDs = mediaResults.compactMap { $0["id"] as? String }
                result[.mediaItem(extension: "")] = Set(mediaIDs)
            } catch {
                didFail = true
            }

            // Fetch AI chat attachment IDs from message-level persisted file records.
            // These files are not represented by a standalone Core Data entity; their
            // ownership lives in AIConversationMessage.filesData.
            do {
                let messageRequest = NSFetchRequest<NSDictionary>(entityName: "AIConversationMessage")
                messageRequest.resultType = .dictionaryResultType
                messageRequest.predicate = NSPredicate(format: "filesData != nil")
                messageRequest.propertiesToFetch = ["filesData"]

                let messages = try context.fetch(messageRequest)
                let decoder = JSONDecoder()
                let attachmentIDs = messages
                    .compactMap { $0["filesData"] as? Data }
                    .flatMap { data -> [String] in
                        guard let persistedFiles = try? decoder.decode([PersistedFile].self, from: data) else {
                            return []
                        }
                        return persistedFiles.compactMap { file in
                            guard file.kind == .local else { return nil }
                            return file.fileID
                        }
                    }
                result[.aiChatAttachment(extension: "")] = Set(attachmentIDs)
            } catch {
                didFail = true
            }

            return didFail ? nil : result
        }
    }

    /// Get valid IDs for a specific content type
    private func getValidIDs(
        for contentType: FileStorageContentType,
        from validFileIDs: [FileStorageContentType: Set<String>]
    ) -> Set<String> {
        // For media items, use the base media item key (ignoring extension)
        if case .mediaItem = contentType {
            return validFileIDs[.mediaItem(extension: "")] ?? []
        }
        // For AI chat attachments, use the base attachment key (ignoring extension).
        if case .aiChatAttachment = contentType {
            return validFileIDs[.aiChatAttachment(extension: "")] ?? []
        }
        return validFileIDs[contentType] ?? []
    }
}
