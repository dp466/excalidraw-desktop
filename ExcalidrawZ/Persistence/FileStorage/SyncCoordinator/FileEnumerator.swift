//
//  FileEnumerator.swift
//  ExcalidrawZ
//
//  Created by Claude on 2025/12/31.
//

import Foundation
import CoreData
import Logging

/// File enumeration from different sources (local, iCloud, CoreData)
struct FileEnumerator {
    private let logger = Logger(label: "FileEnumerator")
    private let localManager: LocalStorageManager
    private let iCloudManager: iCloudDriveFileManager

    init(localManager: LocalStorageManager, iCloudManager: iCloudDriveFileManager) {
        self.localManager = localManager
        self.iCloudManager = iCloudManager
    }

    // MARK: - File Enumeration

    /// Enumerate all local files
    func enumerateLocalFiles() async throws -> [SyncFileState] {
        var files: [SyncFileState] = []

        guard let storageURL = await localManager.getStorageURL() else {
            return files
        }

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: storageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            // Check if it's a regular file
            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            } catch where isFileNotFound(error) {
                // The directory can change while it is being enumerated, such
                // as when Empty Trash removes a checkpoint mid-scan.
                continue
            }
            guard resourceValues.isRegularFile == true else { continue }

            // Get metadata
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: fileURL.filePath)
            } catch where isFileNotFound(error) {
                continue
            }
            let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
            let size = attributes[.size] as? Int64 ?? 0

            // Get relative path safely (handles /private prefix differences)
            let basePath = storageURL.standardizedFileURL.filePath
            let fullPath = fileURL.standardizedFileURL.filePath
            guard fullPath.hasPrefix(basePath) else {
                logger.warning("Skipping file outside storage root: \(fullPath) (base: \(basePath))")
                continue
            }
            let relativePath = normalizedRelativePath(
                String(fullPath.dropFirst(basePath.count))
            )

            // Determine content type from file extension
            guard let contentType = FileStorageContentType.from(relativePath: relativePath) else {
                // Skip files with unknown extensions
                continue
            }

            guard let fileID = extractFileID(from: relativePath, contentType: contentType) else {
                logger.warning("Skipping file with invalid storage path: \(relativePath)")
                continue
            }

            files.append(SyncFileState(
                fileID: fileID,
                relativePath: relativePath,
                contentType: contentType,
                modifiedAt: modifiedAt,
                size: size
            ))
        }
        return files
    }

    /// Enumerate all iCloud files
    /// - macOS: Uses ICloudStatusChecker to get accurate download status
    /// - iOS: Forces metadata refresh via startDownloadingUbiquitousItem
    func enumerateICloudFiles() async throws -> [SyncFileState] {
        var files: [SyncFileState] = []

        guard let containerURL = await iCloudManager.containerURL else {
            return files
        }

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: containerURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            // Check if it's a regular file
            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            } catch where isFileNotFound(error) {
                // Empty Trash can remove this item after the directory
                // enumerator yielded its URL.
                continue
            }
            guard resourceValues.isRegularFile == true else { continue }

            #if os(iOS)
            // iOS: Force refresh metadata from iCloud
            // On iOS, placeholder files may have cached timestamps that don't reflect
            // the actual iCloud state. startDownloadingUbiquitousItem forces iOS to
            // refresh metadata from iCloud.
            do {
                try fileManager.startDownloadingUbiquitousItem(at: fileURL)
                // Give it a moment to update metadata
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            } catch {
                logger.warning("Failed to refresh iCloud metadata for \(fileURL.lastPathComponent): \(error)")
                // Continue anyway with cached metadata
            }
            #endif

            // Get metadata
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: fileURL.filePath)
            } catch where isFileNotFound(error) {
                continue
            }
            let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
            let size = attributes[.size] as? Int64 ?? 0

            // Get relative path safely (handles /private prefix differences)
            let basePath = containerURL.standardizedFileURL.filePath
            let fullPath = fileURL.standardizedFileURL.filePath
            guard fullPath.hasPrefix(basePath) else {
                logger.warning("Skipping iCloud file outside container: \(fullPath) (base: \(basePath))")
                continue
            }
            let relativePath = normalizedRelativePath(
                String(fullPath.dropFirst(basePath.count))
            )

            // Determine content type from file extension
            guard let contentType = FileStorageContentType.from(relativePath: relativePath) else {
                // Skip files with unknown extensions
                continue
            }

            guard let fileID = extractFileID(from: relativePath, contentType: contentType) else {
                logger.warning("Skipping iCloud file with invalid storage path: \(relativePath)")
                continue
            }

            // Get download status (macOS only)
            var downloadStatus: SyncFileState.DownloadStatus? = nil
            #if os(macOS)
            do {
                let iCloudStatus = try await ICloudStatusChecker.shared.checkStatus(for: fileURL)
                downloadStatus = mapToDownloadStatus(iCloudStatus)
            } catch {
                logger.warning("Failed to check iCloud status for \(fileURL.lastPathComponent): \(error)")
                // Continue without download status
            }
            #endif

            files.append(SyncFileState(
                fileID: fileID,
                relativePath: relativePath,
                contentType: contentType,
                modifiedAt: modifiedAt,
                size: size,
                downloadStatus: downloadStatus
            ))
        }

        return files
    }

    private func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return true
        }
        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlyingError.domain == NSPOSIXErrorDomain
                && underlyingError.code == 2
        }
        return false
    }

    /// Map ICloudFileStatus to SyncFileState.DownloadStatus
    #if os(macOS)
    private func mapToDownloadStatus(_ status: ICloudFileStatus) -> SyncFileState.DownloadStatus? {
        switch status {
            case .notDownloaded:
                return .notDownloaded
            case .outdated:
                return .downloaded
            case .downloaded:
                return .current
            default:
                // For other statuses (loading, uploading, downloading, conflict, error, local)
                // return nil as they're not relevant for DiffScan's purposes
                return nil
        }
    }
    #endif

    private func extractFileID(
        from relativePath: String,
        contentType: FileStorageContentType
    ) -> String? {
        let normalizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if case .aiChatAttachment = contentType {
            let prefix = "AIChatAttachments/"
            guard normalizedPath.hasPrefix(prefix) else { return nil }
            let attachmentPath = String(normalizedPath.dropFirst(prefix.count))
            let fileID = (attachmentPath as NSString).deletingPathExtension
            return fileID.isEmpty ? nil : fileID
        }

        let filename = (normalizedPath as NSString).lastPathComponent
        let fileID = (filename as NSString).deletingPathExtension
        return fileID.isEmpty ? nil : fileID
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Enumerate all files that should exist based on CoreData entities
    func enumerateExpectedFiles() async -> [SyncFileState] {
        let context = PersistenceController.shared.newTaskContext()

        // All CoreData operations must run on the context's queue
        return await context.perform {
            var expectedFiles: [SyncFileState] = []

            // Dictionary results: `propertiesToFetch` is ignored for managed
            // objects, so these fetches loaded every row in full, including
            // the inline image data of media items.
            func rows(_ entityName: String, _ properties: [String]) throws -> [[String: Any]] {
                let request = NSFetchRequest<NSDictionary>(entityName: entityName)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = properties
                return try context.fetch(request).compactMap { $0 as? [String: Any] }
            }

            let datedEntities: [(entity: String, contentType: FileStorageContentType, label: String)] = [
                ("File", .file, "File"),
                ("CollaborationFile", .collaborationFile, "CollaborationFile"),
                ("FileCheckpoint", .checkpoint, "FileCheckpoint"),
            ]
            for (entity, contentType, label) in datedEntities {
                do {
                    for row in try rows(entity, ["id", "updatedAt"]) {
                        guard let fileID = (row["id"] as? UUID)?.uuidString,
                              let updatedAt = row["updatedAt"] as? Date else { continue }
                        expectedFiles.append(SyncFileState(
                            fileID: fileID,
                            relativePath: contentType.generateRelativePath(fileID: fileID),
                            contentType: contentType,
                            modifiedAt: updatedAt,
                            size: 0  // Size will be determined from filesystem
                        ))
                    }
                } catch {
                    self.logger.error("Failed to fetch \(label) entities: \(error.localizedDescription)")
                }
            }

            // Fetch all MediaItem entities
            do {
                for row in try rows("MediaItem", ["id", "mimeType", "createdAt"]) {
                    guard let fileID = row["id"] as? String,
                          let mimeType = row["mimeType"] as? String,
                          let createdAt = row["createdAt"] as? Date else { continue }
                    let ext = FileStorageContentType.fileExtension(for: mimeType)
                    let contentType = FileStorageContentType.mediaItem(extension: ext)
                    let relativePath = contentType.generateRelativePath(fileID: fileID)
                    expectedFiles.append(SyncFileState(
                        fileID: fileID,
                        relativePath: relativePath,
                        contentType: contentType,
                        modifiedAt: createdAt,
                        size: 0
                    ))
                }
            } catch {
                self.logger.error("Failed to fetch MediaItem entities: \(error.localizedDescription)")
            }

            // Fetch AI chat attachments referenced by message filesData. These do not
            // have their own Core Data entity, but they are still first-class files
            // under FileStorage and need DiffScan coverage.
            do {
                let messageRequest = NSFetchRequest<NSDictionary>(entityName: "AIConversationMessage")
                messageRequest.resultType = .dictionaryResultType
                messageRequest.predicate = NSPredicate(format: "filesData != nil")
                messageRequest.propertiesToFetch = ["filesData", "timeStamp"]

                let messages = try context.fetch(messageRequest).compactMap { $0 as? [String: Any] }
                let decoder = JSONDecoder()
                var seenAttachmentIDs = Set<String>()

                for message in messages {
                    guard let filesData = message["filesData"] as? Data,
                          let persistedFiles = try? decoder.decode([PersistedFile].self, from: filesData)
                    else { continue }

                    let timestamp = message["timeStamp"] as? Date ?? Date()
                    for file in persistedFiles where file.kind == .local {
                        guard let fileID = file.fileID,
                              let ext = file.ext,
                              seenAttachmentIDs.insert(fileID).inserted
                        else { continue }

                        let contentType = FileStorageContentType.aiChatAttachment(extension: ext)
                        let relativePath = contentType.generateRelativePath(fileID: fileID)
                        expectedFiles.append(SyncFileState(
                            fileID: fileID,
                            relativePath: relativePath,
                            contentType: contentType,
                            modifiedAt: timestamp,
                            size: 0
                        ))
                    }
                }
            } catch {
                self.logger.error("Failed to fetch AI chat attachment records: \(error.localizedDescription)")
            }

            return expectedFiles
        }
    }
}
